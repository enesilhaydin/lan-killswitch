#!/bin/sh
# Fast unit test for the WireGuard endpoint route guard. No root, no real ip.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOD="$HERE/.."

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
has() { printf '%s\n' "$2" | grep -F -- "$1" >/dev/null && ok "$3" || bad "$3"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (beklenen='$3' olan='$2')"; fi; }

echo "== endpoint-guard-test =="

GUARD="$MOD/endpoint-guard.sh"
if [ ! -f "$GUARD" ]; then
    bad "endpoint-guard.sh yok"
    echo
    echo "== sonuc: PASS=$pass FAIL=$fail =="
    exit 1
fi

LKS_ENDPOINT_GUARD_TEST=1 . "$GUARD"

EP=149.102.229.158
ROUTE_DEV=tun0
ROUTE_TABLE=tun0
IP_LOG=$(mktemp 2>/dev/null || echo /tmp/lks_ep_ip.$$)
: > "$IP_LOG"

ip() {
    case "$*" in
        "-o -4 addr show")
            echo "33: sipa_eth0    inet 100.92.199.220/8 brd 100.255.255.255 scope global sipa_eth0"
            ;;
        "-o link show")
            echo "53: tun0: <POINTOPOINT,UP,LOWER_UP> mtu 1380"
            ;;
        "route get $EP")
            echo "$EP dev $ROUTE_DEV table $ROUTE_TABLE src 10.66.232.123 uid 0"
            ;;
        "route show table sipa_eth0")
            echo "default dev sipa_eth0 proto static scope link mtu 1500"
            ;;
        route\ replace*)
            echo "$*" >> "$IP_LOG"
            ;;
        "route flush cache")
            echo "$*" >> "$IP_LOG"
            ;;
        *)
            echo "UNMOCKED ip $*" >&2
            return 1
            ;;
    esac
}

log() { :; }

guard_endpoint "$EP"
out=$(cat "$IP_LOG")
has "route replace $EP/32 dev sipa_eth0 table tun0" "$out" "loop varsa endpoint ayni tun0 tablosunda cellular'a pinlenir"
has "route flush cache" "$out" "pin sonrasi route cache temizlenir"

: > "$IP_LOG"
ROUTE_DEV=sipa_eth0
guard_endpoint "$EP"
out=$(cat "$IP_LOG")
eq "endpoint zaten cellular uzerindeyse route yazilmaz" "$out" ""

rm -f "$IP_LOG" 2>/dev/null

echo
echo "== sonuc: PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1

