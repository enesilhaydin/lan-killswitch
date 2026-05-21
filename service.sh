#!/system/bin/sh
# LAN Kill Switch - service hook (late_start)
# Long-running watchdog: properly daemonized via setsid so it survives
# Magisk's service shell exit. Re-asserts chain + FORWARD hooks every 10s
# and reacts to link UP events via `ip monitor link` when available.

MODDIR=${0%/*}
LOG=/data/adb/lan-killswitch.log
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
CONF="$MODDIR/interfaces.conf"
USER_CONF=/data/adb/lan-killswitch.interfaces

setsid sh -c '
    LOG="'"$LOG"'"
    IPT="'"$IPT"'"
    IPT6="'"$IPT6"'"
    CONF="'"$CONF"'"
    USER_CONF="'"$USER_CONF"'"

    log() { echo "[$(date +%F\ %T)] service: $*" >> "$LOG"; }

    ensure_chain() {
        local ipt=$1 r
        [ "$ipt" = "$IPT" ] && r="icmp-net-unreachable" || r="icmp6-no-route"
        if ! $ipt -L lan_killswitch -n >/dev/null 2>&1; then
            $ipt -N lan_killswitch 2>/dev/null
            $ipt -F lan_killswitch
            $ipt -A lan_killswitch -o tun+ -j RETURN
            $ipt -A lan_killswitch -j REJECT --reject-with $r
            log "re-created chain ($ipt)"
        fi
    }

    ensure_hook() {
        local ipt=$1 iface=$2
        ip link show dev "$iface" >/dev/null 2>&1 || return 0
        if ! $ipt -C FORWARD -i "$iface" -j lan_killswitch 2>/dev/null; then
            $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
            log "re-inserted FORWARD hook on $iface ($ipt)"
        fi
    }

    load_ifaces() {
        local src="$USER_CONF"
        [ -f "$src" ] || src="$CONF"
        grep -vE "^\s*(#|$)" "$src" 2>/dev/null
    }

    sweep() {
        ensure_chain $IPT
        ensure_chain $IPT6
        for iface in $(load_ifaces); do
            ensure_hook $IPT  "$iface"
            ensure_hook $IPT6 "$iface"
        done
    }

    # Wait for boot completion
    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
    log "boot_completed, entering watchdog (10s interval) + link-event listener"

    # Fire an event-driven listener that triggers an immediate sweep
    # whenever a link comes UP. Falls back silently if `ip monitor` is
    # unavailable.
    (
        ip monitor link 2>/dev/null | while read -r line; do
            # An incoming UP event line looks like:
            # "5: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> ..."
            case "$line" in
                *NEWLINK*|*UP*LOWER_UP*) sweep ;;
            esac
        done
    ) &

    # Periodic safety net
    while true; do
        sweep
        sleep 10
    done
' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
