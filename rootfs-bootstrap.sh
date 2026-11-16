#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi
set -x
kernel=`ls kernel/linux*.deb|wc -l`
if [ $kernel -ne 3 ]; then
	echo "Build kernel first"
	exit 1
fi

#Bootstrap the system
rm -rf $1
mkdir $1
chroot_dir=$1
mem_size=`free --giga|grep Mem|awk '{print $2}'`
if [ $mem_size -gt 10 ]; then
	mount -t tmpfs -o size=10G tmpfs $chroot_dir
fi
rm -f wget-log* overlay/kernel_version

suite=$3
#suite=resolute
Uri=$2
#Uri="http://ports.ubuntu.com/ubuntu-ports"
# $4 = rootfs profile:
#   desktop (default) - GNOME + gdm3 + oem-config (first user created on HDMI)
#   server            - headless: openssh-server, default user (password must be
#                       changed on first login), multi-user.target, no display manager
profile=${4:-desktop}
case "$profile" in desktop|server) ;; *) echo "unknown rootfs profile: $profile"; exit 1;; esac
ROOTFS_USER=${ROOTFS_USER:-ubuntu}
	debootstrap --arch=arm64 $suite arm64 $Uri

export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export  LC_ALL=C
export  LC_CTYPE=C
export  LANGUAGE=C
export  LANG=C 

#Setup DNS
echo "127.0.0.1 localhost" > $1/etc/hosts
echo "nameserver 8.8.8.8" > $1/etc/resolv.conf
echo "nameserver 8.8.4.4" >> $1/etc/resolv.conf

#sources.list setup
rm $1/etc/hostname
if [ "$profile" = server ]; then
	echo "ubuntu-server" > $1/etc/hostname
else
	echo "ubuntu-desktop" > $1/etc/hostname
fi
{
echo "Types: deb"
echo "URIs: $Uri"
echo "Suites: $suite $suite-updates $suite-backports"
echo "Components: main universe restricted multiverse"
echo "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
echo ""
echo "## Ubuntu security updates. Aside from URIs and Suites,"
echo "## this should mirror your choices in the previous section."
echo "Types: deb"
echo "URIs: $Uri"
echo "Suites: $suite-security"
echo "Components: main universe restricted multiverse"
echo "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg"
} > $1/etc/apt/sources.list.d/ubuntu.sources
rm -f $1/etc/apt/sources.list

mkdir -p "$1/etc/apt/preferences.d"
{
echo "Package: firefox*"
echo "Pin: release o=LP-PPA-mozillateam"
echo "Pin-Priority: 1001"
echo ""
echo "Package: firefox*"
echo "Pin: release o=Ubuntu"
echo "Pin-Priority: -1"
echo ""
echo "Package: thunderbird*"
echo "Pin: release o=LP-PPA-mozillateam"
echo "Pin-Priority: 1001"
echo ""
echo "Package: thunderbird*"
echo "Pin: release o=Ubuntu"
echo "Pin-Priority: -1"
} > $1/etc/apt/preferences.d/mozillateam-ppa
echo "sudo apt install firefox-esr thunderbird-gnome-support"

{
echo 'Package: *'
echo 'Pin: release o=LP-PPA-xtradeb-apps'
echo 'Pin-Priority: 100'
echo ''
echo 'Package: chromium*'
echo 'Pin: release o=LP-PPA-xtradeb-apps'
echo 'Pin-Priority: 700'
echo ''
echo 'Package: chromium-browser'
echo 'Pin: release *'
echo 'Pin-Priority: -1'
} > $1/etc/apt/preferences.d/xtradeb-chromium-ppa
# kdump not install
cat > "$1/etc/apt/preferences.d/no-kdump" << 'EOF'
Package: kdump-tools
Pin: release *
Pin-Priority: -1
EOF


#setup custom packages

systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get update
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get -y upgrade
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get install -y software-properties-common
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo add-apt-repository -y ppa:mozillateam/ppa
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo add-apt-repository -y ppa:xtradeb/apps 
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get update
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get -y dist-upgrade
# もし他のパッケージでも同じように止まった場合は同じパターンで：
# echo 'パッケージ名 パッケージ名/質問キー boolean false' | debconf-set-selections
if [ "$profile" = desktop ]; then
systemd-nspawn -D $1 \
  --resolv-conf=replace-host \
  --as-pid2 \
  --setenv=DEBIAN_FRONTEND=noninteractive \
  --setenv=DEBCONF_NONINTERACTIVE_SEEN=true \
  /bin/bash -c "echo 'kdump-tools kdump-tools/use_kdump boolean false' | debconf-set-selections && \
  sudo apt-get -y install ubuntu-desktop-minimal gdm3 linux-firmware oem-config-gtk ubiquity-frontend-gtk ubiquity-slideshow-ubuntu yaru-theme-unity yaru-theme-icon yaru-theme-gtk aptdaemon initramfs-tools vim cloud-guest-utils e2fsprogs sudo"
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "sudo apt-get install -y gstreamer1.0-plugins-bad gstreamer1.0-plugins-good gstreamer1.0-tools clapper mpv vulkan-tools mesa-utils"
else
# Headless: no desktop meta-package, so pull in explicitly what it used to bring
# (ssh, mesa runtime that the custom Mesa .debs below replace, GL/VK tools).
systemd-nspawn -D $1 \
  --resolv-conf=replace-host \
  --as-pid2 \
  --setenv=DEBIAN_FRONTEND=noninteractive \
  --setenv=DEBCONF_NONINTERACTIVE_SEEN=true \
  /bin/bash -c "echo 'kdump-tools kdump-tools/use_kdump boolean false' | debconf-set-selections && \
  sudo apt-get -y install linux-firmware initramfs-tools vim cloud-guest-utils e2fsprogs sudo \
  openssh-server ca-certificates curl wget less bash-completion htop pciutils usbutils locales tzdata \
  python3-venv python3-pip \
  libegl1 libgles2 libgl1 libgbm1 libegl-mesa0 libglx-mesa0 libgl1-mesa-dri mesa-vulkan-drivers libvulkan1 \
  gstreamer1.0-plugins-bad gstreamer1.0-plugins-good gstreamer1.0-tools vulkan-tools mesa-utils"
fi
# Chromium (xtradeb PPA, pinned above) + fonts: headless Chromium/Playwright on the
# Panthor GPU (see /usr/local/bin/chromium-gpu-check below).
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "sudo apt-get install -y chromium fonts-liberation fonts-noto-cjk fonts-noto-color-emoji"

# --- Networking / Bluetooth / container runtime (explicit, per porting checklist Section F) ---
# Do not rely on the desktop meta-package to pull these in by accident.
# NOTE: wireless-tools (ifconfig/iwconfig) is obsolete and has NO installation
# candidate in Ubuntu 26.04 (resolute); `iw` (below) + iproute2 (in base) fully
# supersede it for the AP6611 Wi-Fi/BT bring-up. Verified present in resolute:
# network-manager wpasupplicant iw bluez rfkill docker.io containerd.
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "sudo apt-get install -y \
  network-manager wpasupplicant iw bluez rfkill \
  docker.io containerd"
# Compose plugin name differs across releases; install whichever exists.
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "sudo apt-get install -y docker-compose-v2 || sudo apt-get install -y docker-compose-plugin || true"

# Enable services offline (systemctl enable only creates symlinks, no init needed).
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "\
  sudo systemctl enable NetworkManager.service bluetooth.service docker.service || true"

# Host IPv4/IPv6 forwarding must be on for Docker bridge/NAT and reDroid.
cat > $1/etc/sysctl.d/99-redroid-forwarding.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

# Auto-mount binderfs for reDroid via a systemd unit (disk_image.sh rewrites
# /etc/fstab, so an fstab entry would be lost; a mount unit survives).
mkdir -p $1/dev/binderfs
cat > $1/etc/modules-load.d/panthor.conf << 'EOF'
# Panthor (CONFIG_DRM_PANTHOR=m) is the mainline DRM driver for the RK3588
# Mali-G610 (Valhall CSF). Load it early so /dev/dri/renderD* exists before
# reDroid's gpu_config.sh probes for a host GPU. binder / binderfs are built
# into this kernel (CONFIG_ANDROID_BINDER_IPC=y / _BINDERFS=y), so no binder
# module is listed here; only the binderfs mount unit below is required.
panthor
EOF
cat > $1/etc/systemd/system/dev-binderfs.mount << 'EOF'
[Unit]
Description=Android binderfs (reDroid)
DefaultDependencies=no
Before=multi-user.target

[Mount]
What=binder
Where=/dev/binderfs
Type=binderfs
Options=defaults

[Install]
WantedBy=multi-user.target
EOF
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "sudo systemctl enable dev-binderfs.mount || true"

# AP6611 (BCM43711) Wi-Fi/BT firmware: linux-firmware (installed above) ships the
# brcmfmac blobs, but board-specific NVRAM/CLM and the BT hcd (e.g. SYN43711A0.hcd)
# may be vendor-supplied. Drop them into overlay/board-firmware/ to install them.
if [ -d overlay/board-firmware ]; then
	mkdir -p $1/lib/firmware
	cp -a overlay/board-firmware/. $1/lib/firmware/
	echo "Installed board firmware from overlay/board-firmware/"
fi

systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get -y purge cloud-init flash-kernel fwupd nano grub-efi-arm64

systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get update
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get -y upgrade

sed -i 's/#EXTRA_GROUPS=.*/EXTRA_GROUPS="video render docker"/g' $1/etc/adduser.conf
sed -i 's/#ADD_EXTRA_GROUPS=.*/ADD_EXTRA_GROUPS=1/g' $1/etc/adduser.conf

if [ "$profile" = server ]; then
	# No HDMI/oem-config: ship a login user. Initial password = user name, expired
	# so the first (SSH or serial) login must set a new one. Optional SSH keys:
	# overlay/authorized_keys.
	systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "\
	  useradd -m -s /bin/bash -G sudo,adm,video,render,docker $ROOTFS_USER && \
	  echo '$ROOTFS_USER:$ROOTFS_USER' | chpasswd && chage -d 0 $ROOTFS_USER"
	if [ -f overlay/authorized_keys ]; then
		install -d -m 0700 $1/home/$ROOTFS_USER/.ssh
		install -m 0600 overlay/authorized_keys $1/home/$ROOTFS_USER/.ssh/authorized_keys
		systemd-nspawn -D $1 --as-pid2 chown -R $ROOTFS_USER:$ROOTFS_USER /home/$ROOTFS_USER/.ssh
	fi
	# Every board flashed from this image must get its own SSH host keys.
	cat > $1/etc/systemd/system/ssh-hostkeys-firstboot.service << 'EOF'
[Unit]
Description=Generate SSH host keys on first boot
DefaultDependencies=no
After=local-fs.target
Before=ssh.service ssh.socket
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=sockets.target multi-user.target
EOF
	systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 /bin/bash -c "\
	  systemctl enable ssh-hostkeys-firstboot.service && \
	  { systemctl enable ssh.socket 2>/dev/null || systemctl enable ssh.service; } && \
	  systemctl set-default multi-user.target"
fi

# Headless Chromium / Playwright on the GPU. Without X/Wayland Mesa EGL must use
# the surfaceless platform (render node only); the ANGLE backend that works on
# Panthor is picked on the board by `chromium-gpu-check --apply`.
mkdir -p $1/etc/chromium.d/
cat > $1/etc/chromium.d/opi5-gpu << 'EOF'
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then export EGL_PLATFORM=surfaceless; fi
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ignore-gpu-blocklist --enable-gpu-rasterization"
EOF
cat > $1/usr/local/bin/chromium-gpu-check << 'EOF'
#!/bin/bash
# chromium-gpu-check [--apply] : which headless Chromium GPU mode reaches the Mali
# GPU (WebGL UNMASKED_RENDERER must not be SwiftShader/llvmpipe).
#   CHROME=<binary> to test another build (e.g. Playwright's chrome).
# --apply writes the first working mode to /etc/chromium.d/opi5-gpu-mode (sudo).
CHROME=${CHROME:-/usr/lib/chromium/chromium}
[ -x "$CHROME" ] || CHROME=$(command -v chromium)
export EGL_PLATFORM=${EGL_PLATFORM:-surfaceless}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/gl.html" << 'HTML'
<html><body><pre id=o></pre><script>
let o = 'NO-WEBGL';
const gl = document.createElement('canvas').getContext('webgl2') ||
           document.createElement('canvas').getContext('webgl');
if (gl) {
  const e = gl.getExtension('WEBGL_debug_renderer_info');
  o = 'RENDERER=' + (e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)) +
      ' VERSION=' + gl.getParameter(gl.VERSION);
}
document.getElementById('o').textContent = o;
</script></body></html>
HTML
modes=(
  "vulkan|--use-angle=vulkan --enable-features=Vulkan,VulkanFromANGLE,DefaultANGLEVulkan"
  "gl-egl|--use-gl=angle --use-angle=gl-egl"
  "gles-egl|--use-gl=angle --use-angle=gles-egl"
)
win=""
for m in "${modes[@]}"; do
  name=${m%%|*}; flags=${m#*|}
  out=$(timeout 60 "$CHROME" --headless=new --no-first-run --ignore-gpu-blocklist --enable-gpu \
        --enable-gpu-rasterization $flags --virtual-time-budget=5000 \
        --dump-dom "file://$tmp/gl.html" 2>/dev/null | grep -o 'RENDERER=[^<]*\|NO-WEBGL')
  if echo "$out" | grep -q 'RENDERER=' && ! echo "$out" | grep -qiE 'swiftshader|llvmpipe|softpipe|lavapipe'; then
    echo "[ GPU ] $name: $out"; [ -n "$win" ] || win="$flags"
  else
    echo "[ SW  ] $name: ${out:-no output}"
  fi
done
if [ -z "$win" ]; then echo "FAIL: no hardware WebGL in headless Chromium"; exit 1; fi
echo "PASS: use flags: $win"
if [ "$1" = "--apply" ]; then
  echo "export CHROMIUM_FLAGS=\"\$CHROMIUM_FLAGS $win\"" | sudo tee /etc/chromium.d/opi5-gpu-mode
fi
EOF
chmod 0755 $1/usr/local/bin/chromium-gpu-check


# kernel
mkdir $1/kkk && rm -f overlay/libdrm-dev_*.deb overlay/libegl1-mesa-dev_*.deb overlay/libgbm-dev_*.deb && \
rm -f overlay/libgl1-mesa-dev_*.deb overlay/libgles2-mesa-dev_*.deb overlay/mesa-common-dev_*.deb && \
rm -f overlay/mesa-opencl-icd_*.deb overlay/mesa-teflon-delegate_*.deb overlay/mesa-drm-shim_*.deb && \
rm -f overlay/libdrm-tests_*.deb && cp overlay/*.deb $1/kkk && cp -r kernel $1/kkk

systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo /bin/bash -c "sudo apt-get -y purge \$(dpkg --list | grep -Ei 'linux-image|linux-headers|linux-modules|linux-rockchip' | awk '{ print \$2 }')"
# Custom Mesa/libdrm: let apt resolve any runtime deps from the archive (the server
# profile lacks the desktop's implicit ones), never remove packages, and allow the
# "~panthor1" versions that sort below the archive build. Fall back to plain dpkg.
# Then hold them so a later `apt upgrade` cannot swap the archive Mesa back in.
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo /bin/bash -c "cd kkk && \
  { sudo apt-get install -y --no-remove --allow-downgrades ./*.deb || sudo dpkg -i *.deb; } && \
  sudo apt-mark hold \$(for f in *.deb; do dpkg-deb -f \$f Package; done) && \
  sudo dpkg -i kernel/*.deb"
#&& sudo dpkg -i kernel/*conservative*.deb && sudo dpkg -i kernel/*ondemand*.deb"

rm -rf $1/kkk
kernel_version="`ls -1 $1/boot/vmlinu?-*|sed 's#-# #g' | awk '{ print $2 }'|head -1`"
echo "kernel_version=$kernel_version" > overlay/kernel_version
# Rockchip NPU user space (librknnrt / librkllmrt / rknn-toolkit-lite2) for the
# vendor rknpu driver that build-kernel.sh compiled in.
if [ -f rknpu/install-rknn-runtime.sh ]; then
	# librkllmrt.so needs libgomp.so.1 (librknnrt only libstdc++/libc).
	systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get -y install libgomp1
	bash rknpu/install-rknn-runtime.sh $1
fi
# install U-Boot
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get -y install u-boot-tools u-boot-menu

# Default kernel command line arguments
echo -n "rootwait rw console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory" > $1/etc/kernel/cmdline
echo -n " quiet splash plymouth.ignore-serial-consoles" >> $1/etc/kernel/cmdline

# Override u-boot-menu config
mkdir -p $1/usr/share/u-boot-menu/conf.d
cat << 'EOF' > $1/usr/share/u-boot-menu/conf.d/ubuntu.conf
U_BOOT_UPDATE="true"
U_BOOT_PROMPT="1"
U_BOOT_PARAMETERS="$(cat /etc/kernel/cmdline)"
U_BOOT_TIMEOUT="20"
EOF

rm -f $1/var/lib/dbus/machine-id
true > $1/etc/machine-id
touch $1/var/log/syslog
chown root:adm $1/var/log/syslog
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 ssh-keygen -A
# server: host keys are created per board by ssh-hostkeys-firstboot.service
if [ "$profile" = server ]; then rm -f $1/etc/ssh/ssh_host_*; fi
# debug
echo "linux-version"
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 linux-version list

# chromium
mkdir -p $1/etc/chromium.d/
echo 'export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --enable-features=AcceleratedVideoDecoder,V4l2VideoDecode --disable-features=UseChromeOSDirectVideoDecoder"' > $1/etc/chromium.d/opi5-v4l2


systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get -y autoremove
systemd-nspawn -D $1 --resolv-conf=replace-host --as-pid2 sudo apt-get  clean


rm -f wget-log*
rm -f $1/boot/*.old
#tar the rootfs
rootfs="overlay/ubuntu.rootfs.tar.gz"
echo "rootfs=$rootfs" > overlay/rootfs
cd $1
rm -rf ../$rootfs
sync
echo " Now create $rootfs "
tar -zcf ../$rootfs --xattrs --xattrs-include='*' ./*
cd ..
echo "DISK usage"
df $1  
# Exit trap is no longer needed
trap '' EXIT
if [ $mem_size -gt 10 ]; then
	umount $1
	sleep 2
fi
exit 0
