#!/system/bin/sh
# vpn-endpoint-guard — self-healing guard against the WireGuard endpoint
# routing-loop that makes a tethered hotspot "work for 20-60s then die".
#
# THE PROBLEM
#   WireGuard installs a catch-all default route via tun0. The ENCRYPTED
#   handshake/keepalive packets to the WG *server endpoint* must leave via the
#   CELLULAR uplink. WireGuard normally protects this (fwmark / host route). If
#   that protection isn't effective on this firmware, or a cellular re-init
#   (APN cycle -> new cellular IP) drops the protecting route, the endpoint
#   falls onto the default route (tun0) and the handshake packets loop back
#   into the tunnel. The current session survives until the next rekey /
#   keepalive window, then the tunnel goes dead and the hotspot loses internet.
#
# WHAT THIS DOES
#   Every 20s, ONLY while a tun* is up, it checks each WireGuard server
#   endpoint's route. If it resolves via tun* (a loop), it pins a /32 host
#   route to that endpoint via the cellular uplink. Otherwise it does nothing.
#
# SAFETY
#   - Acts only when a loop is actually present (zero-touch when healthy).
#   - If it cannot identify the cellular uplink, it does NOTHING (safe-fail) —
#     it will never blackhole your traffic by guessing.
#   - /32 host route to a single server IP; never touches the default route.
#
# INSTALL (not part of the lan-killswitch Magisk zip — it's a separate helper):
#   cp companion/vpn-endpoint-guard.sh /data/adb/service.d/
#   chmod 755 /data/adb/service.d/vpn-endpoint-guard.sh
#   (reboot, or run it once by hand)
# Debug log: touch /data/adb/vpn-endpoint-guard.debug ; tail -f /data/adb/vpn-endpoint-guard.log

DBG=/data/adb/vpn-endpoint-guard.debug
LOG=/data/adb/vpn-endpoint-guard.log
WG_CONF_DIR=/data/data/com.wireguard.android/files
INTERVAL=20

setsid sh -c '
    DBG="'"$DBG"'"; LOG="'"$LOG"'"; WG_CONF_DIR="'"$WG_CONF_DIR"'"; INTERVAL='"$INTERVAL"'

    log() { [ -f "$DBG" ] && echo "[$(date +%F\ %T)] $*" >> "$LOG"; }

    # IPv4 server endpoints from every WG config (IP:port -> IP). Hostnames are
    # skipped (they need DNS and WireGuard re-resolves them itself).
    endpoints() {
        grep -h "^Endpoint" "$WG_CONF_DIR"/*.conf 2>/dev/null \
            | sed "s/.*=[[:space:]]*//; s/:[0-9]*$//" \
            | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" \
            | sort -u
    }

    # The cellular uplink. ZTE SIPA exposes it as sipa_ethN; prefer an UP one
    # with an IPv4 address. Fallback: the iface of a non-tun default route.
    cell_iface() {
        i=$(ip -o -4 addr show 2>/dev/null | awk "/sipa_eth[0-9]/ {print \$2; exit}")
        [ -n "$i" ] && { echo "$i"; return 0; }
        ip route show table main 2>/dev/null | awk "/^default/ && \$5 !~ /tun/ {print \$5; exit}"
    }

    route_dev() { ip route get "$1" 2>/dev/null | head -1 | sed -n "s/.* dev \([^ ]*\).*/\1/p"; }
    route_tbl() { ip route get "$1" 2>/dev/null | head -1 | sed -n "s/.* table \([^ ]*\).*/\1/p"; }

    # Find how the cellular uplink itself reaches the world, so we can copy that
    # next-hop for the endpoint. Look in the cellular iface own table first,
    # then main. Echoes either "via <gw> dev <cif>" or "dev <cif>".
    cell_nexthop() {
        cif=$1
        for t in "$cif" main; do
            d=$(ip route show table "$t" 2>/dev/null | awk "/^default/{print; exit}")
            [ -n "$d" ] && { echo "$d" | sed "s/^default //; s/ proto.*//; s/ scope.*//"; return 0; }
        done
        echo "dev $cif"
    }

    pin_endpoint() {
        ep=$1; cif=$2
        # Pin the /32 into the SAME table the endpoint is currently looping
        # through (on ZTE that is the tun0 table via ip rule 13000, NOT main),
        # so the very lookup that sends it into tun0 instead finds our cellular
        # route. main-only pinning would be ignored by policy routing.
        tbl=$(route_tbl "$ep"); [ -n "$tbl" ] || tbl=main
        nh=$(cell_nexthop "$cif")
        # try with the cellular next-hop; fall back to a plain dev route
        ip route replace "$ep/32" $nh table "$tbl" 2>/dev/null \
            || ip route replace "$ep/32" dev "$cif" table "$tbl" 2>/dev/null
    }

    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
    log "guard active (interval ${INTERVAL}s)"

    while sleep "$INTERVAL"; do
        ip link show dev tun0 >/dev/null 2>&1 || continue   # only while VPN up
        cif=$(cell_iface); [ -n "$cif" ] || continue        # safe-fail: unknown uplink -> do nothing
        for ep in $(endpoints); do
            dev=$(route_dev "$ep")
            case "$dev" in
                tun*)
                    if pin_endpoint "$ep" "$cif"; then
                        log "LOOP fixed: pinned $ep via $cif (was routing through $dev)"
                    fi
                    ;;
            esac
        done
    done
' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
