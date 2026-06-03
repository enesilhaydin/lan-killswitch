#!/system/bin/sh
# LAN Kill Switch - post-fs-data hook
# Installs the iptables FORWARD-chain interceptor as early as possible
# and keeps retrying for 90s until tether/AP interfaces appear.
# Mutex-guarded so it doesn't race with service.sh's watchdog.

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

    log() { [ -f /data/adb/lan-killswitch.debug ] && echo "[$(date +%F\ %T)] post-fs-data: $*" >> "$LOG"; }

    # mkdir is atomic — acts as a process-wide mutex.
    # Steals stale lock if older than 30s (covers the case where a
    # holder died mid-section).
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
        fi
    }

    # Force-idempotent: delete every existing instance, insert exactly one.
    hook_interface() {
        local ipt=$1 iface=$2
        ip link show dev "$iface" >/dev/null 2>&1 || return 1
        while $ipt -D FORWARD -i "$iface" -j lan_killswitch 2>/dev/null; do : ; done
        $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
        return 0
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
    sync_lan_returns() {
        local ipt=$1 iface
        if [ -f /data/adb/lan-killswitch.allow-lan ]; then
            for iface in $(load_ifaces); do
                $ipt -C lan_killswitch -o "$iface" -j RETURN 2>/dev/null \
                    || $ipt -I lan_killswitch 1 -o "$iface" -j RETURN
            done
        else
            for iface in $(load_ifaces); do
                while $ipt -D lan_killswitch -o "$iface" -j RETURN 2>/dev/null; do : ; done
            done
        fi
    }

    # Wait until iptables is usable
    for i in $(seq 1 60); do
        $IPT -L FORWARD -n >/dev/null 2>&1 && break
        sleep 1
    done

    acquire || { log "lock timeout at startup"; exit 0; }
    ensure_chain $IPT
    ensure_chain $IPT6
    log "chains created"
    release

    declare_hooked=""
    end=$(( $(date +%s) + 90 ))
    while [ "$(date +%s)" -lt "$end" ]; do
        new=""
        acquire || { sleep 2; continue; }
        for iface in $(load_ifaces); do
            if hook_interface $IPT "$iface"; then
                hook_interface $IPT6 "$iface"
                case " $declare_hooked " in
                    *" $iface "*) ;;
                    *) new="$new $iface"; declare_hooked="$declare_hooked $iface" ;;
                esac
            fi
        done
        sync_lan_returns $IPT
        sync_lan_returns $IPT6
        release
        [ -n "$new" ] && log "hooked$new"
        sleep 2
    done
    log "retry phase ended (final:$declare_hooked)"
' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
