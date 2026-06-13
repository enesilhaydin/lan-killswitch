#!/system/bin/sh
# LAN Kill Switch - service hook (late_start)
#
# Lightweight, passive watchdog.
#
# Design rationale (v1.2.0): the FORWARD hook, once installed at boot, is
# effectively permanent. NetD does NOT flush custom-chain jumps living in the
# FORWARD chain (it only rewrites the chains it owns: tetherctrl_*, nat
# POSTROUTING, bw_*). vpn-gateway only ADDS its own rules; it never deletes
# ours. So in practice the hook simply does not disappear after boot.
#
# Because of that, this watchdog deliberately does NOT:
#   - police rule ORDER (hook position is irrelevant to correctness — proof
#     below), and
#   - react to every link event (that caused an ip-monitor sweep storm that
#     fought vpn-gateway over the FORWARD top slot, churning iptables and
#     hurting network stability).
#
# Why position doesn't matter: every vpn-gateway ACCEPT is qualified with
# -o tun0 / -i tun0, i.e. it only matches traffic that SHOULD pass while the
# VPN is up. With the VPN down, tun0 has no route, those ACCEPTs can't match,
# and the packet still reaches our REJECT. With the VPN up, the packet is
# meant to pass anyway. So whether our hook sits above or below vpn-gateway's
# rules, the verdict is identical: blocked when VPN down, allowed when VPN up.
#
# The watchdog therefore only re-installs the hook on the rare chance it is
# genuinely MISSING, on a slow 60s cadence, and touches iptables ONLY when
# something is actually absent or duplicated. Steady state = zero writes.

MODDIR=${0%/*}
LOG=/data/adb/lan-killswitch.log
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
CONF="$MODDIR/interfaces.conf"
USER_CONF=/data/adb/lan-killswitch.interfaces
LOCK=/data/adb/lan-killswitch.lock
INTERVAL=60
ENDPOINT_GUARD="$MODDIR/endpoint-guard.sh"

[ -f "$ENDPOINT_GUARD" ] && sh "$ENDPOINT_GUARD"
export ENDPOINT_GUARD

setsid sh -c '
    LOG="'"$LOG"'"
    IPT="'"$IPT"'"
    IPT6="'"$IPT6"'"
    CONF="'"$CONF"'"
    USER_CONF="'"$USER_CONF"'"
    LOCK="'"$LOCK"'"
    INTERVAL='"$INTERVAL"'

    log() { [ -f /data/adb/lan-killswitch.debug ] && echo "[$(date +%F\ %T)] service: $*" >> "$LOG"; }

    # mkdir is atomic — mutex against post-fs-data during the first ~90s.
    acquire() {
        local tries=0
        while ! mkdir "$LOCK" 2>/dev/null; do
            tries=$((tries+1))
            if [ -d "$LOCK" ]; then
                age=$(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
                [ "$age" -gt 30 ] && rmdir "$LOCK" 2>/dev/null
            fi
            sleep 1
            [ "$tries" -gt 60 ] && return 1
        done
        return 0
    }
    release() { rmdir "$LOCK" 2>/dev/null; }

    # Verify the chain EXISTS and still holds BOTH required rules. Checking mere
    # existence is not enough: a chain that exists but lost its rules is unsafe.
    #   - empty chain        -> implicit RETURN -> packet falls through -> LEAK
    #   - missing tun+ RETURN -> even VPN traffic is rejected -> permanent outage
    # So rebuild whenever either rule is absent, not only when the chain is gone.
    ensure_chain() {
        local ipt=$1 r
        [ "$ipt" = "$IPT" ] && r="icmp-net-unreachable" || r="icmp6-no-route"
        if ! $ipt -L lan_killswitch -n >/dev/null 2>&1 \
           || ! $ipt -C lan_killswitch -o tun+ -j RETURN 2>/dev/null \
           || ! $ipt -C lan_killswitch -j REJECT --reject-with $r 2>/dev/null; then
            $ipt -N lan_killswitch 2>/dev/null
            $ipt -F lan_killswitch
            $ipt -A lan_killswitch -o tun+ -j RETURN
            $ipt -A lan_killswitch -j REJECT --reject-with $r
            log "(re)built chain ($ipt)"
        fi
    }

    # Idempotent. Writes ONLY when the hook is missing (count 0) or somehow
    # duplicated (count >1). count==1 -> no iptables write at all.
    ensure_hook() {
        local ipt=$1 iface=$2 count
        ip link show dev "$iface" >/dev/null 2>&1 || return 0
        count=$($ipt -S FORWARD 2>/dev/null | grep -c -- "-i $iface -j lan_killswitch$")
        if [ "$count" -eq 0 ]; then
            $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
            log "installed missing FORWARD hook on $iface ($ipt)"
        elif [ "$count" -gt 1 ]; then
            while $ipt -D FORWARD -i "$iface" -j lan_killswitch 2>/dev/null; do : ; done
            $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
            log "de-duplicated FORWARD hook on $iface ($ipt) [had:$count]"
        fi
    }

    load_ifaces() {
        local src="$USER_CONF"
        [ -f "$src" ] || src="$CONF"
        grep -vE "^[[:space:]]*(#|$)" "$src" 2>/dev/null
    }

    # Opt-in intra-LAN exception (touch /data/adb/lan-killswitch.allow-lan):
    # permit forwarding BETWEEN local/tether interfaces while still rejecting
    # anything bound for a non-tunnel WAN. Idempotent: only writes when the
    # desired state differs from the current chain (zero writes in steady state).
    sync_lan_returns() {
        local ipt=$1 iface
        if [ -f /data/adb/lan-killswitch.allow-lan ]; then
            for iface in $(load_ifaces); do
                $ipt -C lan_killswitch -o "$iface" -j RETURN 2>/dev/null \
                    || { $ipt -I lan_killswitch 1 -o "$iface" -j RETURN; log "allow-lan +$iface ($ipt)"; }
            done
        else
            for iface in $(load_ifaces); do
                if $ipt -C lan_killswitch -o "$iface" -j RETURN 2>/dev/null; then
                    while $ipt -D lan_killswitch -o "$iface" -j RETURN 2>/dev/null; do : ; done
                    log "allow-lan -$iface ($ipt)"
                fi
            done
        fi
    }

    # Full-tunnel VPN + cellular hotspots can blackhole larger TCP flows when
    # forwarded clients keep an MSS too large for the VPN path. Clamp SYN MSS on
    # both directions of tun+ forwarding. Idempotent, and de-duplicates if a
    # previous service run left more than one copy.
    ensure_mss_rule() {
        local ipt=$1 dir=$2 count
        count=$($ipt -t mangle -S FORWARD 2>/dev/null | grep -c -- "$dir tun+ -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu$")
        if [ "$count" -eq 0 ]; then
            $ipt -t mangle -I FORWARD 1 $dir tun+ -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
            log "installed TCPMSS clamp $dir tun+"
        elif [ "$count" -gt 1 ]; then
            while $ipt -t mangle -D FORWARD $dir tun+ -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do : ; done
            $ipt -t mangle -I FORWARD 1 $dir tun+ -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
            log "de-duplicated TCPMSS clamp $dir tun+ [had:$count]"
        fi
    }

    ensure_mss_clamp() {
        ensure_mss_rule "$1" -o
        ensure_mss_rule "$1" -i
    }

    # Mullvad and other strict providers expect forwarded hotspot packets to
    # leave the tunnel with the tunnel address, not a LAN source like
    # 192.168.0.x. This is only NAT on tun+ egress; it never creates an APN
    # accept/NAT path.
    ensure_tun_masquerade() {
        local ipt=$1 count
        count=$($ipt -t nat -S POSTROUTING 2>/dev/null | grep -c -- "-o tun+ -j MASQUERADE$")
        if [ "$count" -eq 0 ]; then
            $ipt -t nat -I POSTROUTING 1 -o tun+ -j MASQUERADE
            log "installed tun+ MASQUERADE"
        elif [ "$count" -gt 1 ]; then
            while $ipt -t nat -D POSTROUTING -o tun+ -j MASQUERADE 2>/dev/null; do : ; done
            $ipt -t nat -I POSTROUTING 1 -o tun+ -j MASQUERADE
            log "de-duplicated tun+ MASQUERADE [had:$count]"
        fi
    }

    ensure_endpoint_guard() {
        local pid cmd
        [ -f "$ENDPOINT_GUARD" ] || return 0

        pid=$(cat /data/adb/lan-killswitch-endpoint-guard.pid 2>/dev/null)
        if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
            cmd=$(tr "\000" " " < "/proc/$pid/cmdline" 2>/dev/null)
            case "$cmd" in
                *endpoint-guard.sh*"--loop"*) return 0 ;;
            esac
        fi

        rm -f /data/adb/lan-killswitch-endpoint-guard.pid
        sh "$ENDPOINT_GUARD"
        log "restarted endpoint guard"
    }

    sweep() {
        acquire || return
        ensure_endpoint_guard
        ensure_chain $IPT
        ensure_chain $IPT6
        ensure_mss_clamp $IPT
        ensure_tun_masquerade $IPT
        for iface in $(load_ifaces); do
            ensure_hook $IPT  "$iface"
            ensure_hook $IPT6 "$iface"
        done
        sync_lan_returns $IPT
        sync_lan_returns $IPT6
        release
    }

    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
    log "boot_completed, watchdog active (${INTERVAL}s, passive — no order policing, no link listener)"

    while true; do
        sweep
        sleep "$INTERVAL"
    done
' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
