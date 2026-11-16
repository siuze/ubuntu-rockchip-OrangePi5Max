#!/bin/bash
# Orange Pi 5 Max (RK3588) — mainline Panthor image, single-board build.
#
# Correct ordering (the shared pieces are built once):
#   1. build_kernel_env.sh <max defconfig> ... kernel  -> U-Boot(Max) + linux-7.3.y (LINUX_SERIES) .deb (all DTBs) + arm64 build env
#   2. mesa-build-env.sh                              -> Panthor/PanVK Mesa .deb
#   3. rootfs-bootstrap.sh ... $ROOTFS_PROFILE       -> Ubuntu rootfs (installs the kernel + Mesa .debs + RKNN runtime)
#      ROOTFS_PROFILE defaults to server (headless: sshd + default user, no GUI);
#      ROOTFS_PROFILE=desktop restores the GNOME/oem-config image.
#   4. disk_image.sh orangepi-5-max $MAX_DTB         -> the .img (uses the Max U-Boot + Max DTB)
#      MAX_DTB defaults to rk3588-orangepi-5-max-rknpu (vendor RKNPU for librknnrt);
#      MAX_DTB=rk3588-orangepi-5-max selects the stock DTB (mainline rocket NPU).
#
# Usage: ./build-opi5max.sh [upstream|ubuntu]     (mesa_source, default upstream)
# Intended to run on a native arm64 host / CI runner (e.g. GitHub ubuntu-24.04-arm).

set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
	echo "NOTE: not root and no passwordless sudo; the sub-scripts call sudo themselves." >&2
fi

suite=resolute
Uri="http://ports.ubuntu.com/ubuntu-ports"
mesa_source="${1:-upstream}"

start_time="$(date)"
sudo rm -f log?
sudo rm -f overlay/build-versions.txt

LINUX_SERIES=${LINUX_SERIES:-7.3}
MAX_DTB=${MAX_DTB:-rk3588-orangepi-5-max-rknpu}
ROOTFS_PROFILE=${ROOTFS_PROFILE:-server}
echo "==== [1/4] Orange Pi 5 Max : kernel(linux-${LINUX_SERIES}.y) + U-Boot(orangepi-5-max-rk3588_defconfig) + arm64 build env ===="
# sudo drops the caller's environment, so pass the kernel series explicitly.
sudo LINUX_SERIES="$LINUX_SERIES" ${MINIMYTH2_REF:+MINIMYTH2_REF="$MINIMYTH2_REF"} ./build_kernel_env.sh orangepi-5-max-rk3588_defconfig "$Uri" "$suite" kernel
# The sub-scripts have no `set -e` and always `exit 0`, so guard the artifacts
# explicitly to make a CI failure loud instead of silently shipping a bad image.
if ! ls kernel/*.deb >/dev/null 2>&1; then
	echo "FATAL: build_kernel_env.sh produced no kernel/*.deb" >&2
	exit 1
fi
if [ ! -f overlay/u-boot-rockchip.bin ]; then
	echo "FATAL: no overlay/u-boot-rockchip.bin (Max U-Boot) produced" >&2
	exit 1
fi
# build_kernel_env.sh already saved the built kernel .config to overlay/2-config.txt
# (copied out before the arm64 tmpfs is unmounted). Give it a stable name for the audit.
if [ -f overlay/2-config.txt ]; then
	cp overlay/2-config.txt overlay/kernel-built-.config
	echo "saved overlay/kernel-built-.config (from overlay/2-config.txt)"
else
	echo "WARNING: overlay/2-config.txt not found; kernel .config not captured" >&2
fi

echo "==== [2/4] Mesa (panthor gallium + panvk) : source=$mesa_source ===="
sudo ./mesa-build-env.sh arm64 "$mesa_source" "$Uri" "$suite"
if ! ls overlay/*.deb >/dev/null 2>&1; then
	echo "FATAL: mesa-build-env.sh produced no overlay/*.deb" >&2
	exit 1
fi

echo "==== [3/4] Rootfs (Ubuntu $suite, profile $ROOTFS_PROFILE) ===="
sudo ./rootfs-bootstrap.sh arm64 "$Uri" "$suite" "$ROOTFS_PROFILE"
# rootfs-bootstrap.sh writes overlay/rootfs (a FILE: rootfs=overlay/ubuntu.rootfs.tar.gz)
# plus the tarball itself; disk_image.sh sources that file to locate the tarball.
if [ ! -f overlay/rootfs ] || ! ls overlay/*.rootfs.tar.gz >/dev/null 2>&1; then
	echo "FATAL: rootfs-bootstrap.sh produced no overlay/rootfs + overlay/*.rootfs.tar.gz" >&2
	exit 1
fi

echo "==== [4/4] Disk image : orangepi-5-max / DTB $MAX_DTB ===="
sudo ./disk_image.sh arm64 orangepi-5-max "$MAX_DTB"
if ! ls images/*.img* >/dev/null 2>&1; then
	echo "FATAL: disk_image.sh produced no images/*.img*" >&2
	exit 1
fi
sudo mv overlay/u-boot-rockchip.bin overlay/orangepi-5-MAX-u-boot-rockchip.bin

echo "==== build versions (linux / u-boot / rkbin commit SHA) ===="
if [ -f overlay/build-versions.txt ]; then
	cat overlay/build-versions.txt
else
	echo "WARNING: overlay/build-versions.txt was not produced" >&2
fi

echo "start: $start_time"
echo "end:   $(date)"
echo "==== images ===="
ls -lh images/ 2>/dev/null || true
