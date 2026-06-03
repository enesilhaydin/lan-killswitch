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

    log() { [ -f /data/adb/lan-killswitch.debug ] && echo "[$(date +%F\ %T)] service: $*" >> "$LOG"; }

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
        grep -vE "^[[:space:]]*(#|$)" "$src" 2>/dev/null
    }

    # Opt-in intra-LAN exception (touch /data/adb/lan-killswitch.allow-lan):
    # permit forwarding BETWEEN local/tether interfaces while still rejecting
    # anything bound for a non-tunnel WAN. The chain is only ever entered for
    # -i <protected iface>, so an -o <protected iface> RETURN can only allow
    # LAN-internal forwarding, never WAN egress. Default (no flag) = full deny.
    # Toggling the flag is picked up on the next sweep (<=10s), no reboot.
    sync_lan_returns() {
        local ipt=$1 iface
        if [ -f /data/adb/lan-killswitch.allow-lan ]; then
            for iface in $(load_ifaces); do
                $ipt -C lan_killswitch -o "$iface" -j RETURN 2>/dev/null \
                    || { $ipt -I lan_killswitch 1 -o "$iface" -j RETURN; log "allow-lan: +$iface ($ipt)"; }
            done
        else
            for iface in $(load_ifaces); do
                while $ipt -D lan_killswitch -o "$iface" -j RETURN 2>/dev/null; do : ; done
            done
        fi
    }

    # Guarantee all of our FORWARD hooks sit at the very top, above any ACCEPT
    # another module (e.g. a VPN routing module) may have inserted after us.
    # Checking only "exactly one hook exists" is not enough: a single hook can
    # still end up *below* a foreign ACCEPT and be silently bypassed.
    ensure_top() {
        local ipt=$1 total topc tmp line iface
        total=$($ipt -S FORWARD 2>/dev/null | grep -c -- "-j lan_killswitch")
        [ "$total" -eq 0 ] && return 0
        # Count how many of the LEADING FORWARD rules are ours (contiguous from
        # the top). Read from a temp file, not a pipe, so the counter survives.
        tmp=/data/adb/lan-killswitch.fwd.$$
        $ipt -S FORWARD 2>/dev/null | grep "^-A FORWARD" > "$tmp"
        topc=0
        while IFS= read -r line; do
            case "$line" in
                *"-j lan_killswitch") topc=$((topc+1)) ;;
                *) break ;;
            esac
        done < "$tmp"
        rm -f "$tmp"
        [ "$topc" -eq "$total" ] && return 0
        # Drift: a foreign rule sits above one of our hooks. We hold the mutex,
        # so re-lift cleanly: drop every hook, then reinsert each configured +
        # present interface at position 1 (back on top).
        for iface in $(load_ifaces); do
            while $ipt -D FORWARD -i "$iface" -j lan_killswitch 2>/dev/null; do : ; done
        done
        for iface in $(load_ifaces); do
            ip link show dev "$iface" >/dev/null 2>&1 && $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
        done
        log "lifted hooks back to top ($ipt) [was $topc/$total]"
    }

    sweep() {
        acquire || return
        ensure_chain $IPT
        ensure_chain $IPT6
        for iface in $(load_ifaces); do
            ensure_hook $IPT  "$iface"
            ensure_hook $IPT6 "$iface"
        done
        sync_lan_returns $IPT
        sync_lan_returns $IPT6
        ensure_top $IPT
        ensure_top $IPT6
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
