#!/bin/bash

# Fail fast: never continue to the next board if a build step errors, so we do
# not silently ship an image built with another board's DTB / U-Boot.
set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

#suite=plucky
suite=resolute
#Uri="http://ftp.udx.icscoe.jp/Linux/ubuntu-ports/"
Uri="http://ports.ubuntu.com/ubuntu-ports"


	start_time=`date`

	# Board table: <u-boot defconfig> <image board name> <linux dtb basename>
	# The kernel/rootfs/Mesa are built once and shared by every board below; only
	# U-Boot and the DTB reference (U_BOOT_FDT) differ per board.
	sudo rm -f log?
	sudo rm -f overlay/build-versions.txt

	echo "==== [1/3] Orange Pi 5 (RK3588S) : kernel + u-boot + mesa + rootfs ===="
	sudo ./build_kernel_env.sh orangepi-5-rk3588s_defconfig $Uri $suite kernel
	sudo ./mesa-build-env.sh arm64 $1 $Uri $suite
	#sudo ./meas-build-env.sh arm64 ubuntu $Uri $suite
	sudo ./rootfs-bootstrap.sh arm64 $Uri $suite
	sudo ./disk_image.sh arm64 orangepi-5 rk3588s-orangepi-5
	sudo mv overlay/u-boot-rockchip.bin overlay/orangepi-5-u-boot-rockchip.bin

	echo "==== [2/3] Orange Pi 5 Plus (RK3588) : u-boot + image ===="
	sudo ./build_kernel_env.sh orangepi-5-plus-rk3588_defconfig $Uri $suite u-boot
	sudo ./disk_image.sh arm64 orangepi-5-plus rk3588-orangepi-5-plus
	sudo mv overlay/u-boot-rockchip.bin overlay/orangepi-5-PLUS-u-boot-rockchip.bin

	echo "==== [3/3] Orange Pi 5 Max (RK3588) : u-boot + image ===="
	sudo ./build_kernel_env.sh orangepi-5-max-rk3588_defconfig $Uri $suite u-boot
	sudo ./disk_image.sh arm64 orangepi-5-max rk3588-orangepi-5-max
	sudo mv overlay/u-boot-rockchip.bin overlay/orangepi-5-MAX-u-boot-rockchip.bin

	echo "==== build versions (linux / u-boot / rkbin commit SHA) ===="
	if [ -f overlay/build-versions.txt ]; then
		cat overlay/build-versions.txt
	else
		echo "WARNING: overlay/build-versions.txt was not produced" >&2
	fi

	echo "$start_time"
	date

