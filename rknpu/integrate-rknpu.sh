#!/bin/bash
# Graft the Rockchip vendor rknpu driver (v0.9.8, mainline port by w568w) into
# a mainline kernel tree as drivers/rknpu (CONFIG_ROCKCHIP_RKNPU), and add the
# rk3588-orangepi-5-max-rknpu.dtb that wires the NPU for it.
#
# Usage: integrate-rknpu.sh <linux-source-dir>
# Env:   RKNPU_REPO / RKNPU_REF to override the pinned source, or
#        RKNPU_SRC=<local rknpu-module checkout> to skip the network.
#
# Why vendor rknpu and not mainline rocket: .rknn/.rkllm models only run via
# Rockchip's closed librknnrt/librkllmrt, which speak the rknpu ioctl ABI.

set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

linux=$(realpath "$1")
here=$(dirname "$(realpath "$0")")
RKNPU_REPO=${RKNPU_REPO:-https://github.com/w568w/rknpu-module.git}
# Pinned: vendor rknpu 0.9.8 ported to mainline 6.19/7.0 (GPL-2.0).
RKNPU_REF=${RKNPU_REF:-a8792fe6b633f90cf2c6808267cac327537ab4cf}

[ -f "$linux/Makefile" ] && [ -d "$linux/drivers" ] || { echo "not a linux tree: $linux" >&2; exit 1; }

tmp=$(mktemp -d)
if [ -n "$RKNPU_SRC" ]; then
	src=$(realpath "$RKNPU_SRC")
	RKNPU_REF="local:$src"
else
	src="$tmp/rknpu-module"
	for try in 1 2 3 4 5; do
		rm -rf "$src"
		if git clone --filter=blob:none --no-checkout "$RKNPU_REPO" "$src" &&
		   git -C "$src" checkout -q "$RKNPU_REF"; then
			break
		fi
		[ $try = 5 ] && { echo "FATAL: cannot fetch $RKNPU_REPO@$RKNPU_REF" >&2; exit 1; }
		sleep 10
	done
fi

dst="$linux/drivers/rknpu"
rm -rf "$dst"
mkdir -p "$dst"
cp "$src"/src/*.c "$dst/"
cp -r "$src"/src/include "$dst/include"
echo "rknpu-module: $RKNPU_REPO@$RKNPU_REF" > "$dst/SOURCE"
rm -rf "$tmp"

cat > "$dst/Kconfig" <<'EOF'
# SPDX-License-Identifier: GPL-2.0
config ROCKCHIP_RKNPU
	tristate "Rockchip vendor RKNPU driver (librknnrt ABI)"
	depends on DRM && OF && (ARCH_ROCKCHIP || COMPILE_TEST)
	depends on IOMMU_API
	select DMA_SHARED_BUFFER
	select SYNC_FILE
	select PM_OPP
	help
	  Rockchip BSP NPU driver (vendor 0.9.8) as used by the closed
	  librknnrt / librkllmrt runtimes for .rknn / .rkllm models.
	  Exposes a DRM render node named "rknpu". Do not use together with
	  DRM_ACCEL_ROCKET on the same NPU nodes.
EOF

cat > "$dst/Makefile" <<'EOF'
# SPDX-License-Identifier: GPL-2.0
obj-$(CONFIG_ROCKCHIP_RKNPU) += rknpu.o
rknpu-y := rknpu_drv.o rknpu_gem.o rknpu_fence.o rknpu_job.o \
	   rknpu_reset.o rknpu_iommu.o rknpu_debugger.o rknpu_devfreq.o
ccflags-y += -I$(src)/include -I$(src)/include/compat
ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_DRM_GEM
ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_DEBUG_FS
ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_FENCE
EOF

grep -q 'drivers/rknpu/Kconfig' "$linux/drivers/Kconfig" ||
	sed -i 's|^endmenu|source "drivers/rknpu/Kconfig"\n\nendmenu|' "$linux/drivers/Kconfig"
grep -q 'drivers/rknpu/Kconfig' "$linux/drivers/Kconfig"
grep -q '^obj-\$(CONFIG_ROCKCHIP_RKNPU)' "$linux/drivers/Makefile" ||
	echo 'obj-$(CONFIG_ROCKCHIP_RKNPU)	+= rknpu/' >> "$linux/drivers/Makefile"

# Mainline shim: make sure the cores are out of reset before the first job
# (the vendor flow relies on the BSP bootloader/CRU state).
grep -q 'bring NPU cores out of reset' "$dst/rknpu_drv.c" ||
	perl -0pi -e 's{(\n\tif \(rknpu_dev->config->state_init != NULL\))}{\n\t/* bring NPU cores out of reset */\n\t\{\n\t\tint __ri;\n\t\tfor (__ri = 0; __ri < rknpu_dev->num_srsts; __ri++)\n\t\t\treset_control_deassert(rknpu_dev->srsts[__ri]);\n\t\}\n$1}' "$dst/rknpu_drv.c"
grep -q 'bring NPU cores out of reset' "$dst/rknpu_drv.c" ||
	{ echo "FATAL: reset-deassert shim did not apply" >&2; exit 1; }

# Device tree: vendor-layout NPU on top of the stock Max dts.
dts="$linux/arch/arm64/boot/dts/rockchip"
cp "$here/rk3588-rknpu-vendor.dtsi" "$here/rk3588-orangepi-5-max-rknpu.dts" "$dts/"
grep -q 'rk3588-orangepi-5-max-rknpu.dtb' "$dts/Makefile" ||
	sed -i 's|^\(dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-orangepi-5-max.dtb\)$|\1\ndtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-orangepi-5-max-rknpu.dtb|' "$dts/Makefile"
grep -q 'rk3588-orangepi-5-max-rknpu.dtb' "$dts/Makefile" ||
	echo 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3588-orangepi-5-max-rknpu.dtb' >> "$dts/Makefile"

echo "rknpu integrated into $linux ($RKNPU_REF)"
