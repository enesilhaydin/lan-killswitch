#!/system/bin/sh
# Keep WireGuard's encrypted server endpoint packets out of the tunnel.
#
# On some Android router firmwares a full-tunnel WireGuard route makes the WG
# server endpoint itself resolve via tun0. The tunnel then eats its own
# handshake/keepalive packets and dies after the next keepalive window. This
# guard only writes when that loop is visible, pinning the endpoint /32 into the
# same policy routing table that was sending it through tun0.

DBG=/data/adb/lan-killswitch.debug
LOG=/data/adb/lan-killswitch.log
PIDFILE=/data/adb/lan-killswitch-endpoint-guard.pid
WG_CONF_DIR=${WG_CONF_DIR:-/data/data/com.wireguard.android/files}
INTERVAL=${LKS_ENDPOINT_GUARD_INTERVAL:-5}

log() { [ -f "$DBG" ] && echo "[$(date +%F\ %T)] endpoint-guard: $*" >> "$LOG"; }

endpoints() {
    grep -h "^Endpoint" "$WG_CONF_DIR"/*.conf 2>/dev/null \
        | sed "s/.*=[[:space:]]*//; s/:[0-9]*$//" \
        | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$" \
        | sort -u
}

has_tun() {
    ip -o link show 2>/dev/null | grep -q "^[0-9][0-9]*: tun[0-9][0-9]*:"
}

cell_iface() {
    local i
    i=$(ip -o -4 addr show 2>/dev/null | awk "/sipa_eth[0-9]/ {print \$2; exit}")
    [ -n "$i" ] && { echo "$i"; return 0; }

    ip route show table all 2>/dev/null \
        | awk '
            /^default/ && $0 !~ / dev (tun|dummy|lo)/ && $0 ~ / dev (sipa_eth|rmnet|ccmni|wwan|wwp)/ {
                for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
            }'
}

route_dev() {
    ip route get "$1" 2>/dev/null | head -1 | sed -n "s/.* dev \([^ ]*\).*/\1/p"
}

route_tbl() {
    ip route get "$1" 2>/dev/null | head -1 | sed -n "s/.* table \([^ ]*\).*/\1/p"
}

route_tail() {
    sed "s/^default //; s/ table [^ ]*//; s/ proto .*//; s/ scope .*//; s/ metric .*//; s/ mtu .*//"
}

cell_nexthop() {
    local cif=$1 d

    for t in "$cif" main; do
        d=$(ip route show table "$t" 2>/dev/null | awk "/^default/{print; exit}")
        [ -n "$d" ] && { echo "$d" | route_tail; return 0; }
    done

    d=$(ip route show table all 2>/dev/null \
        | awk -v cif="$cif" '
            /^default/ {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev" && $(i + 1) == cif) { print; exit }
                }
            }')
    [ -n "$d" ] && { echo "$d" | route_tail; return 0; }

    echo "dev $cif"
}

pin_endpoint() {
    local ep=$1 cif=$2 tbl nh
    tbl=$(route_tbl "$ep")
    [ -n "$tbl" ] || tbl=main
    nh=$(cell_nexthop "$cif")

    if ip route replace "$ep/32" $nh table "$tbl" 2>/dev/null; then
        ip route flush cache 2>/dev/null
        return 0
    fi
    if ip route replace "$ep/32" dev "$cif" table "$tbl" 2>/dev/null; then
        ip route flush cache 2>/dev/null
        return 0
    fi
    return 1
}

guard_endpoint() {
    local ep=$1 cif dev
    dev=$(route_dev "$ep")
    case "$dev" in
        tun*)
            cif=$(cell_iface)
            [ -n "$cif" ] || { log "loop seen for $ep via $dev, but cellular iface unknown"; return 0; }
            if pin_endpoint "$ep" "$cif"; then
                log "fixed loop: pinned $ep via $cif (was $dev)"
            else
                log "failed to pin $ep via $cif (was $dev)"
            fi
            ;;
    esac
}

[ "${LKS_ENDPOINT_GUARD_TEST:-0}" = "1" ] && { return 0 2>/dev/null || exit 0; }

run_loop() {
    old=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$old" ] && kill -0 "$old" 2>/dev/null && exit 0
    echo $$ > "$PIDFILE"
    trap "rm -f \"$PIDFILE\"" EXIT

    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
    log "active (${INTERVAL}s)"

    while true; do
        if has_tun; then
            for ep in $(endpoints); do
                guard_endpoint "$ep"
            done
        fi
        sleep "$INTERVAL"
    done
}

[ "${1:-}" = "--loop" ] && run_loop

setsid sh "$0" --loop </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
