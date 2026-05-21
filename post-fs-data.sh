#!/system/bin/sh
# LAN Kill Switch - post-fs-data hook
# Installs the iptables FORWARD-chain interceptor as early as possible
# and keeps retrying for the first 90s until tether/AP interfaces appear.
# (post-fs-data runs BEFORE Android brings up br0/wlan0/usb0 in many ROMs.)

MODDIR=${0%/*}
LOG=/data/adb/lan-killswitch.log
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
CONF="$MODDIR/interfaces.conf"
USER_CONF=/data/adb/lan-killswitch.interfaces

log() { echo "[$(date '+%F %T')] post-fs-data: $*" >> "$LOG"; }

load_interfaces() {
    local src
    if [ -f "$USER_CONF" ]; then src="$USER_CONF"; else src="$CONF"; fi
    grep -vE '^\s*(#|$)' "$src" 2>/dev/null
}

iface_exists() { ip link show dev "$1" >/dev/null 2>&1; }

install_chain() {
    local ipt=$1 reject_with
    [ "$ipt" = "$IPT" ] && reject_with="icmp-net-unreachable" || reject_with="icmp6-no-route"
    $ipt -N lan_killswitch 2>/dev/null
    $ipt -F lan_killswitch
    $ipt -A lan_killswitch -o tun+ -j RETURN
    $ipt -A lan_killswitch -j REJECT --reject-with $reject_with
}

hook_interface() {
    local ipt=$1 iface=$2
    iface_exists "$iface" || return 1
    $ipt -C FORWARD -i "$iface" -j lan_killswitch 2>/dev/null \
        || $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
    return 0
}

# Detach into a proper daemon: setsid + nohup + new session, fully orphaned
# to init so Magisk's PID context exiting doesn't reap us.
setsid sh -c '
    LOG="'"$LOG"'"
    IPT="'"$IPT"'"
    IPT6="'"$IPT6"'"

    # Wait until iptables is usable
    for i in $(seq 1 60); do
        $IPT -L FORWARD -n >/dev/null 2>&1 && break
        sleep 1
    done

    # Re-source helpers inline (this shell does not inherit functions)
    install_chain() {
        local ipt=$1 r
        [ "$ipt" = "$IPT" ] && r="icmp-net-unreachable" || r="icmp6-no-route"
        $ipt -N lan_killswitch 2>/dev/null
        $ipt -F lan_killswitch
        $ipt -A lan_killswitch -o tun+ -j RETURN
        $ipt -A lan_killswitch -j REJECT --reject-with $r
    }
    hook_interface() {
        local ipt=$1 iface=$2
        ip link show dev "$iface" >/dev/null 2>&1 || return 1
        $ipt -C FORWARD -i "$iface" -j lan_killswitch 2>/dev/null \
            || $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
    }
    load_ifaces() {
        local src="'"$USER_CONF"'"
        [ -f "$src" ] || src="'"$CONF"'"
        grep -vE "^\s*(#|$)" "$src" 2>/dev/null
    }

    install_chain $IPT
    install_chain $IPT6
    echo "[$(date +%F\ %T)] post-fs-data: chains created" >> "$LOG"

    # Retry phase: every 2s for up to 90s. Each loop hooks any newly-existing
    # interface. Logs once when each interface is first hooked.
    end=$(( $(date +%s) + 90 ))
    declare_hooked=""
    while [ "$(date +%s)" -lt "$end" ]; do
        new=""
        for iface in $(load_ifaces); do
            if hook_interface $IPT "$iface"; then
                hook_interface $IPT6 "$iface"
                case " $declare_hooked " in
                    *" $iface "*) ;;
                    *) new="$new $iface"; declare_hooked="$declare_hooked $iface" ;;
                esac
            fi
        done
        [ -n "$new" ] && echo "[$(date +%F\ %T)] post-fs-data: hooked$new" >> "$LOG"
        sleep 2
    done
    echo "[$(date +%F\ %T)] post-fs-data: retry phase ended (final:$declare_hooked)" >> "$LOG"
' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
