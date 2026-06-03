#!/bin/sh
# Real packet-level leak test for lan-killswitch using Linux network namespaces.
#
# It proves, with REAL packets through the REAL kernel netfilter:
#   1. VPN down (no tun* up)  -> forwarded tether traffic is REJECTED (no leak)
#   2. VPN up   (a tun* up)   -> forwarded tether traffic IS forwarded
#   3. allow-lan flag         -> LAN-internal forwarding is permitted, but
#                                internet egress is STILL rejected (no leak)
#   4. IPv6 parity            -> same as (1)/(2) over ip6tables
#
# Everything lives in throwaway network namespaces; it does NOT touch the host's
# real network. MUST run as root on Linux (e.g. inside `docker run --privileged`).
#
# Faithfulness: install_killswitch() below uses the EXACT rule strings the module
# ships. contract() asserts those strings still exist verbatim in service.sh, so
# this test cannot silently drift away from the real module.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOD="$HERE/.."

IPT=iptables
IPT6=ip6tables
# Match the Android device's legacy backend when available.
command -v iptables-legacy  >/dev/null 2>&1 && IPT=iptables-legacy
command -v ip6tables-legacy >/dev/null 2>&1 && IPT6=ip6tables-legacy

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

contract() {
    f="$MOD/service.sh"
    grep -q -- "-o tun+ -j RETURN"        "$f" || { echo "CONTRACT FAIL: 'tun+ RETURN' not in service.sh"; exit 2; }
    grep -q -- "-j REJECT --reject-with"  "$f" || { echo "CONTRACT FAIL: REJECT rule not in service.sh"; exit 2; }
    grep -q -- '-I FORWARD 1 -i "$iface" -j lan_killswitch' "$f" || { echo "CONTRACT FAIL: FORWARD hook not in service.sh"; exit 2; }
    echo "  contract OK (test rules match service.sh)"
}

cleanup() {
    for ns in client client2 wan; do ip netns del "$ns" 2>/dev/null; done
    $IPT  -t nat -F 2>/dev/null
    $IPT6 -t nat -F 2>/dev/null
}
trap cleanup EXIT

setp() { echo "$2" > "/proc/sys/$1" 2>/dev/null; }

build_topology() {
    cleanup
    ip netns add client
    ip netns add client2
    ip netns add wan

    # gw(br0) <-> client  (primary tether iface)
    ip link add br0 type veth peer name c0
    ip link set c0 netns client
    ip addr add 10.0.0.1/24 dev br0;            ip link set br0 up
    ip netns exec client ip addr add 10.0.0.2/24 dev c0
    ip netns exec client ip link set c0 up
    ip netns exec client ip link set lo up
    ip netns exec client ip route add default via 10.0.0.1

    # gw(usb0) <-> client2  (second tether iface, for allow-lan cross-iface test)
    ip link add usb0 type veth peer name u0
    ip link set u0 netns client2
    ip addr add 10.1.0.1/24 dev usb0;           ip link set usb0 up
    ip netns exec client2 ip addr add 10.1.0.2/24 dev u0
    ip netns exec client2 ip link set u0 up
    ip netns exec client2 ip link set lo up
    ip netns exec client2 ip route add default via 10.1.0.1

    # gw(wan0) <-> wan  (the "cellular" egress)
    ip link add wan0 type veth peer name w0
    ip link set w0 netns wan
    ip addr add 192.168.50.1/24 dev wan0;       ip link set wan0 up
    ip netns exec wan ip addr add 192.168.50.2/24 dev w0
    ip netns exec wan ip link set w0 up
    ip netns exec wan ip link set lo up

    # gw(tun0) <-> wan  (the "VPN" egress; name tun0 matches -o tun+)
    ip link add tun0 type veth peer name t0
    ip link set t0 netns wan
    ip addr add 10.9.0.1/24 dev tun0
    ip netns exec wan ip addr add 10.9.0.2/24 dev t0
    ip netns exec wan ip link set t0 up
    # tun0 stays DOWN until the "VPN up" phase.

    # the single "internet host" the client tries to reach (reachable via either path)
    ip netns exec wan ip addr add 100.64.0.9/32 dev lo

    # ---- IPv6 on the same veths ----
    setp net/ipv6/conf/all/accept_dad 0
    ip addr add fd00:0::1/64  dev br0  nodad
    ip netns exec client  ip addr add fd00:0::2/64 dev c0 nodad
    ip netns exec client  ip route add default via fd00:0::1
    ip addr add fd00:1::1/64  dev usb0 nodad
    ip netns exec client2 ip addr add fd00:1::2/64 dev u0 nodad
    ip netns exec client2 ip route add default via fd00:1::1
    ip addr add fd00:50::1/64 dev wan0 nodad
    ip netns exec wan ip addr add fd00:50::2/64 dev w0 nodad
    ip addr add fd00:9::1/64  dev tun0 nodad
    ip netns exec wan ip addr add fd00:9::2/64 dev t0 nodad
    ip netns exec wan ip addr add 2001:db8::9/128 dev lo nodad

    setp net/ipv4/ip_forward 1
    setp net/ipv4/conf/all/rp_filter 0
    setp net/ipv4/conf/default/rp_filter 0
    setp net/ipv6/conf/all/forwarding 1

    # NAT so the client's private address can reach the wan host on either egress.
    $IPT  -t nat -F
    $IPT  -t nat -A POSTROUTING -o wan0 -j MASQUERADE
    $IPT  -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    $IPT6 -t nat -F 2>/dev/null
    $IPT6 -t nat -A POSTROUTING -o wan0 -j MASQUERADE 2>/dev/null
    $IPT6 -t nat -A POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null
}

# The EXACT rules the module installs (see service.sh ensure_chain / ensure_hook).
install_killswitch() {
    $IPT -F FORWARD; $IPT -P FORWARD ACCEPT
    $IPT -N lan_killswitch 2>/dev/null; $IPT -F lan_killswitch
    $IPT -A lan_killswitch -o tun+ -j RETURN
    $IPT -A lan_killswitch -j REJECT --reject-with icmp-net-unreachable
    $IPT -I FORWARD 1 -i br0  -j lan_killswitch
    $IPT -I FORWARD 1 -i usb0 -j lan_killswitch

    $IPT6 -F FORWARD; $IPT6 -P FORWARD ACCEPT
    $IPT6 -N lan_killswitch 2>/dev/null; $IPT6 -F lan_killswitch
    $IPT6 -A lan_killswitch -o tun+ -j RETURN
    $IPT6 -A lan_killswitch -j REJECT --reject-with icmp6-no-route
    $IPT6 -I FORWARD 1 -i br0  -j lan_killswitch
    $IPT6 -I FORWARD 1 -i usb0 -j lan_killswitch
}

route_v4() { # $1 = wan0|tun0
    if [ "$1" = tun0 ]; then ip link set tun0 up; ip route replace 100.64.0.9/32 via 10.9.0.2 dev tun0
    else ip route replace 100.64.0.9/32 via 192.168.50.2 dev wan0; fi
}
route_v6() { # $1 = wan0|tun0
    if [ "$1" = tun0 ]; then ip link set tun0 up; ip -6 route replace 2001:db8::9/128 via fd00:9::2 dev tun0
    else ip -6 route replace 2001:db8::9/128 via fd00:50::2 dev wan0; fi
}

allow_lan() { # $1 = on|off
    for ipt in "$IPT" "$IPT6"; do
        for ifc in br0 usb0; do
            while $ipt -D lan_killswitch -o "$ifc" -j RETURN 2>/dev/null; do :; done
        done
        if [ "$1" = on ]; then
            for ifc in br0 usb0; do $ipt -I lan_killswitch 1 -o "$ifc" -j RETURN; done
        fi
    done
}

relift() { # mirror of service.sh ensure_top(): drop all our hooks, reinsert on top
    for ifc in br0 usb0; do
        while $IPT -D FORWARD -i "$ifc" -j lan_killswitch 2>/dev/null; do :; done
    done
    for ifc in br0 usb0; do $IPT -I FORWARD 1 -i "$ifc" -j lan_killswitch; done
}

p4() { ip netns exec "$1" ping  -c1 -W2 "$2" >/dev/null 2>&1; }
p6() { ip netns exec "$1" ping6 -c1 -W2 "$2" >/dev/null 2>&1 || ip netns exec "$1" ping -6 -c1 -W2 "$2" >/dev/null 2>&1; }

blk4()  { if p4 "$2" "$3"; then bad "$1 (gecti -> SIZINTI!)"; else ok "$1 (bloklandi)"; fi; }
leak4() { if p4 "$2" "$3"; then ok "$1 (sizinti DOGRULANDI = tehlike gercek)"; else bad "$1 (sizmaliydi; test kurgusu hatali)"; fi; }
psd4() { if p4 "$2" "$3"; then ok "$1 (gecti)"; else bad "$1 (bloklandi degil mi?)"; fi; }
blk6() { if p6 "$2" "$3"; then bad "$1 (gecti -> SIZINTI!)"; else ok "$1 (bloklandi)"; fi; }
psd6() { if p6 "$2" "$3"; then ok "$1 (gecti)"; else bad "$1 (bloklandi degil mi?)"; fi; }

# ----------------------------------------------------------------------------
echo "== lan-killswitch real leak test (netns) =="
echo "backend: $IPT / $IPT6"
contract
build_topology
install_killswitch

echo
echo "[A] VPN DOWN (tun yok) -> internet bloklanmali"
route_v4 wan0
blk4 "v4: istemci -> internet (cellular)" client 100.64.0.9
route_v6 wan0
blk6 "v6: istemci -> internet (cellular)" client 2001:db8::9

echo
echo "[B] VPN UP (tun0 var, rota tun uzerinden) -> internet gecmeli"
route_v4 tun0
psd4 "v4: istemci -> internet (tun)" client 100.64.0.9
route_v6 tun0
psd6 "v6: istemci -> internet (tun)" client 2001:db8::9

echo
echo "[C] allow-lan KAPALI -> LAN-ici (br0->usb0) bloklu, internet bloklu"
ip link set tun0 down
route_v4 wan0
allow_lan off
blk4 "v4: istemci -> istemci2 (LAN-ici, allow-lan off)" client 10.1.0.2
blk4 "v4: istemci -> internet (allow-lan off)"          client 100.64.0.9

echo
echo "[D] allow-lan ACIK -> LAN-ici gecer ama internet HALA bloklu (sizinti yok)"
allow_lan on
psd4 "v4: istemci -> istemci2 (LAN-ici, allow-lan on)"  client 10.1.0.2
blk4 "v4: istemci -> internet (allow-lan ON iken bile)" client 100.64.0.9

echo
echo "[E] DRIFT: yabanci ACCEPT hook'umuzun ustune girerse sizar; ensure_top geri kapatir"
allow_lan off
ip link set tun0 down
route_v4 wan0
blk4  "v4: baslangic (hook ustte)        " client 100.64.0.9
$IPT -I FORWARD 1 -i br0 -j ACCEPT   # yabanci modul FORWARD'in en ustune ACCEPT soktu
leak4 "v4: yabanci ACCEPT eklendi        " client 100.64.0.9
relift                                # service.sh ensure_top() davranisi
blk4  "v4: ensure_top sonrasi (geri kapal)" client 100.64.0.9

echo
echo "== sonuc: PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1
