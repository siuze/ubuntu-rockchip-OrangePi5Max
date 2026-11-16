#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

set -x

linux_dir=$1
rm -rf $linux_dir && mkdir $linux_dir
cd $linux_dir

# Stable series to build. 7.2.y is EOL; 7.3.y is the current stable.
# Switch to 7.4 only after minimyth2 publishes script/kernel/linux-7.4.
LINUX_SERIES=${LINUX_SERIES:-7.3}
# Pinned minimyth2 commit: all patches below verified to apply on v7.3.4.
MINIMYTH2_REF=${MINIMYTH2_REF:-4a2e857f5e7f018cd481451eeeda719406781f9a}

echo "Downloading rkvdec2 (VDPU381 VP9 etc.) patches from minimyth2 linux-${LINUX_SERIES}..."
mkdir minimyth2 && cd minimyth2
for p in \
	3559-media-rkvdec-fix-PM-runtime-teardown-ordering-in-remove.patch \
	3565-media-rkvdec-remove-vb2_is_busy-check-in-rkvdec_s_ct.patch \
	3566-media-v4l2-core-Initialize-h264-frame_mbs_only_flag-as-1.patch \
	3569-media-rkvdec-prime-VDPU383-deblock-warmup-rk3576.patch \
	3570-media-rkvdec-add-VP9-VDPU381-decoder-support.patch \
	3571-media-rkvdec-vp9-fix-altref-vscale-and-segmap-size-for-2K-decode.patch \
	3572-media-rkvdec-vdpu381-add-VP9-profile-2-10bit-support.patch \
	3573-media-rkvdec-vdpu381-vp9-use-the-real-buffer-stride.patch \
	3574-media-rkvdec-Add-support-for-the-VDPU346-variant.patch
do
	wget --tries=5 --waitretry=10 https://raw.githubusercontent.com/warpme/minimyth2/${MINIMYTH2_REF}/script/kernel/linux-${LINUX_SERIES}/files/$p
done

cd ..

git clone --depth 1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git -b linux-${LINUX_SERIES}.y

cd linux
# Record the exact Linux source used.
{
	echo "linux-branch: linux-${LINUX_SERIES}.y"
	echo "minimyth2-ref: ${MINIMYTH2_REF}"
	echo "linux-commit: $(git rev-parse HEAD)"
	echo "linux-describe: $(git describe 2>/dev/null || echo unknown)"
} >> /build-versions.txt
# minimyth2 patch
for i in ../minimyth2/*.patch
do
        echo $i
        patch -p1 < $i
done
# Vendor RKNPU driver (w568w/rknpu-module) + RK3588 vendor NPU DT -> drivers/rknpu,
# rk3588-orangepi-5-max-rknpu.dtb. Must run before config merge (adds Kconfig).
if [ -d /rknpu ]; then
        bash /rknpu/integrate-rknpu.sh .
        echo "rknpu: $(cat drivers/rknpu/SOURCE)" >> /build-versions.txt
fi
cp /my-add.txt .
wget https://raw.githubusercontent.com/archlinuxarm/PKGBUILDs/refs/heads/master/core/linux-aarch64/config

#make defconfig
./scripts/kconfig/merge_config.sh -m config ./my-add.txt

./scripts/config --set-val DEBUG_INFO_NONE y
./scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
./scripts/config --disable DEBUG_INFO_DWARF4
./scripts/config --disable DEBUG_INFO_DWARF5

make olddefconfig
sed -i 's/CONFIG_LOCALVERSION="-ARCH"/CONFIG_LOCALVERSION=""/' .config
cp .config /2-config.txt

export KCFLAGS="-march=armv8-a+crypto+crc -mtune=cortex-a76.cortex-a55"
fakeroot make -j$(nproc) LOCALVERSION="-rockchip"  deb-pkg
cd ..
cp *.deb /


# Exit trap is no longer needed
trap '' EXIT

exit 0
