#!/system/bin/sh
# LAN Kill Switch - service hook (late_start)
# Properly daemonized watchdog. Re-asserts chain + FORWARD hooks every
# 10s and reacts to link UP events via `ip monitor link`.
# Mutex-guarded so it never races with post-fs-data or with itself
# (periodic sweep vs. event-driven sweep).

MODDIR=${0%/*}
LOG=/data/adb/lan-killswitch.log
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
CONF="$MODDIR/interfaces.conf"
USER_CONF=/data/adb/lan-killswitch.interfaces
LOCK=/data/adb/lan-killswitch.lock

setsid sh -c '
    LOG="'"$LOG"'"
    IPT="'"$IPT"'"
    IPT6="'"$IPT6"'"
    CONF="'"$CONF"'"
    USER_CONF="'"$USER_CONF"'"
    LOCK="'"$LOCK"'"

    log() { echo "[$(date +%F\ %T)] service: $*" >> "$LOG"; }

    acquire() {
        local tries=0
        while ! mkdir "$LOCK" 2>/dev/null; do
            tries=$((tries+1))
            if [ -d "$LOCK" ]; then
                age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
                if [ "$age" -gt 30 ]; then
                    rmdir "$LOCK" 2>/dev/null
                fi
            fi
            sleep 1
            [ "$tries" -gt 60 ] && return 1
        done
        return 0
    }
    release() { rmdir "$LOCK" 2>/dev/null; }

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
        # If duplicates exist or hook is missing, normalize to exactly one.
        local count
        count=$($ipt -S FORWARD 2>/dev/null | grep -c "\-i $iface -j lan_killswitch$")
        if [ "$count" -ne 1 ]; then
            while $ipt -D FORWARD -i "$iface" -j lan_killswitch 2>/dev/null; do : ; done
            $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
            log "normalized FORWARD hook on $iface ($ipt) [had:$count]"
        fi
    }

    load_ifaces() {
        local src="$USER_CONF"
        [ -f "$src" ] || src="$CONF"
        grep -vE "^\s*(#|$)" "$src" 2>/dev/null
    }

    sweep() {
        acquire || return
        ensure_chain $IPT
        ensure_chain $IPT6
        for iface in $(load_ifaces); do
            ensure_hook $IPT  "$iface"
            ensure_hook $IPT6 "$iface"
        done
        release
    }

    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
    log "boot_completed, entering watchdog (10s) + link-event listener"

    # Event-driven: immediate sweep on any link change.
    (
        ip monitor link 2>/dev/null | while read -r line; do
            case "$line" in
                *NEWLINK*|*UP*LOWER_UP*) sweep ;;
            esac
        done
    ) &

    # Periodic safety net.
    while true; do
        sweep
        sleep 10
    done
' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
