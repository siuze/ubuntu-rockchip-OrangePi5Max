#!/bin/bash
# install-rknn-runtime.sh <rootfs-dir>
#
# Installs the Rockchip NPU user space into a rootfs so RKNN models (e.g. the
# *.rknn / *.rkllm files published on HuggingFace for rk3588) run on the vendor
# rknpu driver (drivers/rknpu, version 0.9.8):
#   /usr/lib/librknnrt.so            RKNN runtime (C API, rknn_model_zoo demos)
#   /usr/lib/librkllmrt.so           RKLLM runtime (LLM *.rkllm models)
#   /usr/include/rknn_*.h rkllm.h    headers
#   /opt/rknn/wheels/*.whl           rknn-toolkit-lite2 (Python API, cp310-cp312)
#   /usr/local/bin/uv, rknn-venv     the distro Python (resolute: 3.14) is too new
#                                    for the wheels -> `rknn-venv` builds a 3.12 venv
#   /etc/udev/rules.d/60-rknpu.rules  render/dma_heap access for group "render"
#
# Everything is pinned to an upstream commit and verified by sha256. Downloads
# retry (CI / flaky networks). Override RKNN_TK2_COMMIT/RKLLM_COMMIT only
# together with the matching sha256 table below.
#
# Runtime vs. model version: a .rknn converted by rknn-toolkit2 X needs
# librknnrt >= X, so the newest runtime is shipped (it still loads older models).
set -eE
trap 'echo "Error: in $0 on line $LINENO" >&2' ERR

root="${1:?usage: $0 <rootfs-dir>}"

# rknn-toolkit2 v2.5.0 / rknn-llm release-v1.3.1
RKNN_TK2_COMMIT=2c723177a94fac65cbc036d722907ddbc91980cf
RKLLM_COMMIT=f7390530443bf84f0394255a449d7cbe81e69d1c
TK2="https://raw.githubusercontent.com/airockchip/rknn-toolkit2/${RKNN_TK2_COMMIT}"
LLM="https://raw.githubusercontent.com/airockchip/rknn-llm/${RKLLM_COMMIT}"
WHL_DIR=rknn-toolkit-lite2/packages
WHL_TAG=manylinux_2_17_aarch64.manylinux2014_aarch64
UV_VERSION=0.13.8
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-aarch64-unknown-linux-gnu.tar.gz"
UV_SHA256=74f2f5c6024d397481db228db8fc25eed420db192243f88438c118e7e013e585

# url  sha256  destination(relative to rootfs)  mode
FILES="
$TK2/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so 4b6cc575bedf8952b13db4b1190fa3b3d2ac213f00be774ff6ccd19d651970c0 usr/lib/librknnrt.so 0755
$TK2/rknpu2/runtime/Linux/librknn_api/include/rknn_api.h 2d4160cd868efd7b83a72587e411c16d6972da5876e067bd73665cea778ce666 usr/include/rknn_api.h 0644
$TK2/rknpu2/runtime/Linux/librknn_api/include/rknn_custom_op.h af5983da0ca244ca31dc3162aa683322b0285531196c7a770f29cd2e3b8ccaa6 usr/include/rknn_custom_op.h 0644
$TK2/rknpu2/runtime/Linux/librknn_api/include/rknn_matmul_api.h aaadd9a7118de30a06b222996b6731db77095d00f5931a7a98c83a67f14a4d42 usr/include/rknn_matmul_api.h 0644
$LLM/rkllm-runtime/Linux/librkllm_api/aarch64/librkllmrt.so f25e9b099db08aaacd0a3ac62b4697d3951d6ae61ae41ea09f6702cfa89eb32c usr/lib/librkllmrt.so 0755
$LLM/rkllm-runtime/Linux/librkllm_api/include/rkllm.h 4ad19442de58df1b7d1ed0884ed75b8d4b5107cc4e75b7e44900b1f95a32c57c usr/include/rkllm.h 0644
$TK2/$WHL_DIR/rknn_toolkit_lite2-2.5.0-cp310-cp310-$WHL_TAG.whl 57a5a1f967ff88a1f933abc15a64cf11db37fb406c00cb610f20a566ec231161 opt/rknn/wheels/rknn_toolkit_lite2-2.5.0-cp310-cp310-$WHL_TAG.whl 0644
$TK2/$WHL_DIR/rknn_toolkit_lite2-2.5.0-cp311-cp311-$WHL_TAG.whl 1f1ef5df21d0abf9c8d6d582e21fb8226c2f7ffc17d7744cd18260a7343d503f opt/rknn/wheels/rknn_toolkit_lite2-2.5.0-cp311-cp311-$WHL_TAG.whl 0644
$TK2/$WHL_DIR/rknn_toolkit_lite2-2.5.0-cp312-cp312-$WHL_TAG.whl 5cea0e6ff6e52974debf21719b4499803b5ab62550107274e709846531bf53e1 opt/rknn/wheels/rknn_toolkit_lite2-2.5.0-cp312-cp312-$WHL_TAG.whl 0644
"

fetch() { # url sha256 out
	local i
	for i in 1 2 3 4 5 6; do
		# A failed transfer keeps the .part so the next round resumes (-C -).
		if curl -fsSL --retry 3 --connect-timeout 30 -C - -o "$3.part" "$1"; then
			if echo "$2  $3.part" | sha256sum -c --quiet -; then
				mv "$3.part" "$3"
				return 0
			fi
			# Complete but wrong content: never resume on top of it.
			rm -f "$3.part"
		fi
		echo "fetch retry $i: $1" >&2
		sleep $((i * 10))
	done
	echo "FATAL: cannot fetch $1" >&2
	return 1
}

echo "$FILES" | while read -r url sum dest mode; do
	[ -n "$url" ] || continue
	mkdir -p "$root/$(dirname "$dest")"
	fetch "$url" "$sum" "$root/$dest"
	chmod "$mode" "$root/$dest"
	echo "installed /$dest"
done

mkdir -p "$root/usr/local/bin"
fetch "$UV_URL" "$UV_SHA256" /tmp/uv-aarch64.tar.gz
tar -xzf /tmp/uv-aarch64.tar.gz -C "$root/usr/local/bin" --strip-components=1 \
	uv-aarch64-unknown-linux-gnu/uv uv-aarch64-unknown-linux-gnu/uvx
rm -f /tmp/uv-aarch64.tar.gz
cat > "$root/usr/local/bin/rknn-venv" << 'EOF'
#!/bin/sh
# rknn-venv [dir]: Python 3.12 venv with rknn-toolkit-lite2 (needs network once;
# uv fetches CPython 3.12 + numpy etc.). Then: . <dir>/bin/activate
set -e
d="${1:-$HOME/rknn-venv}"
uv venv -p 3.12 "$d"
VIRTUAL_ENV="$d" uv pip install /opt/rknn/wheels/rknn_toolkit_lite2-*-cp312-cp312-*.whl
echo "ready: . $d/bin/activate && python -c 'from rknnlite.api import RKNNLite'"
EOF
chmod 0755 "$root/usr/local/bin/rknn-venv"

{
	echo "rknn-toolkit2 (librknnrt 2.5.0, rknn-toolkit-lite2 2.5.0): airockchip/rknn-toolkit2@${RKNN_TK2_COMMIT}"
	echo "rknn-llm (librkllmrt 1.3.1): airockchip/rknn-llm@${RKLLM_COMMIT}"
	echo "kernel driver: rknpu 0.9.8 (drivers/rknpu), DTB rk3588-orangepi-5-max-rknpu.dtb"
	echo "python: rknn-venv [dir] -> Python 3.12 venv with rknn-toolkit-lite2 2.5.0 (uv ${UV_VERSION}; wheels in /opt/rknn/wheels, cp310-cp312 only)"
} > "$root/opt/rknn/VERSIONS"

# librknnrt picks the DRM render node whose driver name is "rknpu" and also
# allocates from /dev/dma_heap; let the "render" group (default user is in it,
# see EXTRA_GROUPS in rootfs-bootstrap.sh) use both without root.
mkdir -p "$root/etc/udev/rules.d"
cat > "$root/etc/udev/rules.d/60-rknpu.rules" << 'EOF'
SUBSYSTEM=="dma_heap", GROUP="render", MODE="0660"
EOF

# /usr/lib is on the default search path; refresh the cache anyway.
if [ -x "$root/sbin/ldconfig" ] || [ -x "$root/usr/sbin/ldconfig" ]; then
	chroot "$root" ldconfig || true
fi
echo "RKNN runtime installed into $root"
