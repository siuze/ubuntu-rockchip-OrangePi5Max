#!/bin/bash
# check-kernel-config.sh - verify a *built* kernel .config against the Orange Pi 5
# Max / Panthor / reDroid requirements from the porting checklist (Section E).
#
# The checklist warns that my-add.txt is only a merge fragment: a symbol missing
# from the fragment is NOT necessarily disabled. Therefore this tool checks the
# final .config, not the fragment. Always run `make olddefconfig` first and check
# the resulting .config (this script cannot run olddefconfig for you).
#
# Usage:
#   ./check-kernel-config.sh [path/to/.config]
#   zcat /proc/config.gz | ./check-kernel-config.sh -
#
# Exit code 0 = all REQUIRED options satisfied, 1 = at least one failure.

set -u

cfg_file="${1:-}"
if [ -z "$cfg_file" ]; then
	if [ -r /proc/config.gz ]; then
		cfg_file="/proc/config.gz"
	elif [ -r "/boot/config-$(uname -r)" ]; then
		cfg_file="/boot/config-$(uname -r)"
	else
		echo "usage: $0 <path-to-.config | ->" >&2
		exit 2
	fi
fi

# Read the whole config into a temp file (handles gz, stdin, or plain file).
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
case "$cfg_file" in
	-)            cat > "$tmp" ;;
	*.gz)         zcat "$cfg_file" > "$tmp" ;;
	*)            [ -r "$cfg_file" ] || { echo "cannot read $cfg_file" >&2; exit 2; }; cat "$cfg_file" > "$tmp" ;;
esac

echo "Checking kernel config: $cfg_file"
echo

# getcfg SYMBOL -> echoes y | m | n  (n means "not set" or absent)
getcfg() {
	local line val
	line="$(grep -E "^CONFIG_$1=" "$tmp" | head -1)"
	if [ -n "$line" ]; then
		val="${line#CONFIG_$1=}"
		val="${val%%#*}"                       # strip inline comment (fragment style)
		val="$(printf '%s' "$val" | tr -d '[:space:]')"
		echo "$val"
		return
	fi
	echo "n"
}

PASS=0
FAIL=0
WARN=0

# check SYMBOL EXPECTED KIND
#   EXPECTED: y | m | ym | n   (ym = y or m both acceptable)
#   KIND: REQUIRED | WARN
check() {
	local sym="$1" want="$2" kind="${3:-REQUIRED}"
	local got; got="$(getcfg "$sym")"
	local ok=0
	case "$want" in
		y)  [ "$got" = "y" ] && ok=1 ;;
		m)  [ "$got" = "m" ] && ok=1 ;;
		ym) { [ "$got" = "y" ] || [ "$got" = "m" ]; } && ok=1 ;;
		n)  [ "$got" = "n" ] && ok=1 ;;
	esac
	if [ "$ok" = "1" ]; then
		printf '  [ OK ]  CONFIG_%-34s = %s (want %s)\n' "$sym" "$got" "$want"
		PASS=$((PASS+1))
	else
		if [ "$kind" = "WARN" ]; then
			printf '  [WARN]  CONFIG_%-34s = %s (want %s)\n' "$sym" "$got" "$want"
			WARN=$((WARN+1))
		else
			printf '  [FAIL]  CONFIG_%-34s = %s (want %s)\n' "$sym" "$got" "$want"
			FAIL=$((FAIL+1))
		fi
	fi
}

echo "== GPU / Panthor =="
check DRM y
check DRM_PANTHOR ym
check ROCKCHIP_IOMMU y
# Panthor auto-selects these; verify they are effectively enabled.
check DRM_SCHED ym WARN
check SYNC_FILE y WARN
check DMA_SHARED_BUFFER y
check DRM_GEM_SHMEM_HELPER y WARN
check DMABUF_HEAPS y
check DMABUF_HEAPS_SYSTEM y
check DMABUF_HEAPS_CMA ym WARN   # keep only if the graphics/video path needs it
# Vendor Mali CSF driver must NOT be bound to the same GPU as Panthor.
check MALI_BIFROST n REQUIRED
check MALI_KBASE n WARN
echo

echo "== Docker / reDroid =="
check NAMESPACES y
check PID_NS y
check NET_NS y
check UTS_NS y
check IPC_NS y
check USER_NS y
check CGROUPS y
check CGROUP_DEVICE y
check CGROUP_CPUACCT y
check CGROUP_PIDS y
check CGROUP_SCHED y
check MEMCG y
check CPUSETS y
check OVERLAY_FS ym
check SECCOMP y
check SECCOMP_FILTER y
check ANDROID_BINDER_IPC ym
check ANDROID_BINDERFS ym
check PSI y
check VETH ym
check BRIDGE ym
check BRIDGE_NETFILTER ym
check TUN ym
check NETFILTER y
check NF_CONNTRACK ym
check NETFILTER_XTABLES ym
check NFT_NAT ym WARN
check NF_NAT ym
check NETFILTER_XT_MATCH_ADDRTYPE ym WARN
check NETFILTER_XT_MATCH_CONNTRACK ym WARN
check NETFILTER_XT_TARGET_MASQUERADE ym WARN
check IP_NF_IPTABLES ym
check IP_NF_FILTER ym
check IP_NF_NAT ym
check IP_NF_TARGET_MASQUERADE ym WARN
echo

echo "== IPv6 (Docker) =="
check IPV6 y
check IP6_NF_IPTABLES ym
check IP6_NF_FILTER ym WARN
check IP6_NF_NAT ym WARN
check IP6_NF_TARGET_MASQUERADE ym WARN
echo

echo "== Wi-Fi / Bluetooth (AP6611) =="
check CFG80211 ym
check MAC80211 ym
check RFKILL ym
# AP6611 is a Broadcom SDIO part -> brcmfmac is the mainline driver.
check BRCMFMAC ym
check BRCMFMAC_SDIO y WARN
check BT ym
check BT_RFCOMM ym
check BT_BNEP ym
check BT_HCIUART ym
check BT_HCIUART_BCM ym   # Broadcom HCI UART (hci_bcm SerDev) for the BT side
# Do NOT assume the RTL8852BE fragment entry is the Max on-board Wi-Fi.
check RTW89_8852BE n WARN
echo

echo "==================== summary ===================="
echo "  PASS: $PASS    FAIL: $FAIL    WARN: $WARN"
echo "================================================="
echo
echo "NOTE: If any REQUIRED symbol differs, re-run 'make olddefconfig' and inspect"
echo "      the resulting .config; the fragment (my-add.txt) is not authoritative."
echo "      Also run Docker's official check-config.sh for the full container set."

[ "$FAIL" -eq 0 ]
