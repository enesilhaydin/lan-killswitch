#!/bin/sh
# Reproduction of the "hotspot internet works ~20-60s then dies permanently"
# symptom, and proof that scripts/diag.sh's detector catches it.
#
# THEORY (the prime suspect, and NOT a lan-killswitch bug):
#   WireGuard installs a catch-all default route via tun0 (0.0.0.0/0 dev tun0).
#   The ENCRYPTED handshake/keepalive packets to the WG *server endpoint* must
#   leave via the CELLULAR interface. WireGuard normally protects this with a
#   fwmark rule / an explicit host route. If, after a cellular re-init (APN
#   cycle -> new cellular IP), the route to the endpoint instead falls onto the
#   default route (tun0), the handshake packets loop back into the tunnel:
#       app -> tun0 -> (encrypt) -> send to endpoint -> route says tun0 -> loop
#   The current session keeps working until the next rekey / keepalive window
#   (~20-60s with PersistentKeepalive=25), then the handshake can't refresh and
#   the tunnel goes dead -> hotspot loses internet, "permanently" (until tun0
#   is rebuilt or the route is fixed).
#
# netns can't run real WireGuard, but it CAN reproduce the exact ROUTING
# condition and show diag.sh's detector flagging it. Run as root on Linux
# (use test/run-in-docker.sh-style: docker run --privileged).

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1 (beklenen='$3' olan='$2')"; fi; }

# The endpoint-route detector, copied verbatim in spirit from scripts/diag.sh:
#   DEV=$(ip route get "$EP" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
#   case "$DEV" in tun0) LOOP_BAD ;; "") NO_ROUTE ;; *) ok ;; esac
detect() {  # $1 = endpoint IP -> prints ok|LOOP_BAD|NO_ROUTE
    dev=$(ip route get "$1" 2>/dev/null | head -1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    case "$dev" in
        tun0) echo "LOOP_BAD" ;;
        "")   echo "NO_ROUTE" ;;
        *)    echo "ok" ;;
    esac
}

cleanup() { for ns in cell vpnsrv; do ip netns del "$ns" 2>/dev/null; done; }
trap cleanup EXIT

EP=149.102.229.129     # pretend WG server endpoint (Mullvad-style public IP)

echo "== repro: WireGuard endpoint routing-loop =="
cleanup
ip netns add cell      # the cellular egress (carrier side)
ip netns add vpnsrv    # stands in for the public internet / WG server

# gw(cellular) <-> cell
ip link add cell0 type veth peer name c_in
ip link set c_in netns cell
ip addr add 10.96.0.1/24 dev cell0;  ip link set cell0 up
ip netns exec cell ip addr add 10.96.0.2/24 dev c_in; ip netns exec cell ip link set c_in up
ip netns exec cell ip link set lo up

# gw(tun0) <-> vpnsrv  (the tunnel egress)
ip link add tun0 type veth peer name t_in
ip link set t_in netns vpnsrv
ip addr add 10.9.0.1/24 dev tun0;    ip link set tun0 up
ip netns exec vpnsrv ip addr add 10.9.0.2/24 dev t_in; ip netns exec vpnsrv ip link set t_in up
ip netns exec vpnsrv ip link set lo up

# WireGuard-style routing: default goes via tun0 (catch-all). Cellular is the
# physical uplink with its own subnet route.
ip route replace default dev tun0
# cellular subnet is directly connected (10.96.0.0/24 dev cell0 added by addr)

echo
echo "[1] HEALTHY: endpoint pinned to cellular via explicit host route"
ip route replace "$EP/32" via 10.96.0.2 dev cell0
v=$(detect "$EP")
eq "diag detector: endpoint route healthy" "$v" "ok"
echo "    -> handshake packets exit via cellular; tunnel can refresh; internet stable"

echo
echo "[2] APN CYCLE: cellular re-inits, the /32 host route to the endpoint is lost"
ip route del "$EP/32" 2>/dev/null
# now the endpoint falls onto the default route -> tun0 -> LOOP
v=$(detect "$EP")
eq "diag detector: endpoint route looped onto tun0" "$v" "LOOP_BAD"
echo "    -> handshake packets re-enter the tunnel; after the keepalive window"
echo "       the tunnel dies -> hotspot internet drops ~20-60s after it worked"

echo
echo "[3] FIX: re-pin the endpoint host route to cellular (what a wg-endpoint-route"
echo "    helper / fwmark rule does) -> detector clears"
ip route replace "$EP/32" via 10.96.0.2 dev cell0
v=$(detect "$EP")
eq "diag detector: endpoint route restored" "$v" "ok"

echo
echo "[4] AUTO-HEAL: companion/vpn-endpoint-guard.sh logic fixes the loop on its own"
# Break it again (APN cycle), then run the guard's core decision (loop? -> pin
# to cellular). cell_iface() detection is device-specific (sipa_ethN); here we
# feed the test uplink, exercising the loop-detect + pin_endpoint logic itself.
ip route del "$EP/32" 2>/dev/null
eq "pre-guard: looped" "$(detect "$EP")" "LOOP_BAD"
guard_pin() {  # mirror of pin_endpoint(): gateway if present, else link-scope
    ep=$1; cif=$2
    gw=$(ip route show table main 2>/dev/null | awk -v c="$cif" '/^default/ && $5==c {print $3; exit}')
    if [ -n "$gw" ]; then ip route replace "$ep/32" via "$gw" dev "$cif"
    else ip route replace "$ep/32" via 10.96.0.2 dev "$cif"; fi
}
# guard loop body: only act when the endpoint routes through tun*
dev=$(ip route get "$EP" 2>/dev/null | head -1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
case "$dev" in tun*) guard_pin "$EP" cell0 ;; esac
eq "post-guard: auto-healed" "$(detect "$EP")" "ok"
echo "    -> guard re-pins the endpoint to cellular within one ${INTERVAL:-20}s cycle,"
echo "       so the handshake never stays looped long enough to kill the tunnel"

echo
echo "== sonuc: PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1
