#!/system/bin/sh
# vpn-gateway-watchdog — keep the tun0 MASQUERADE rule alive.
#
# A VPN routing module (e.g. Kr328/vpn-gateway) installs a POSTROUTING
# MASQUERADE on tun0 so hotspot clients' private source IPs are rewritten to
# the tunnel IP — required by strict-NAT providers like Mullvad, which drop
# packets whose source isn't the tunnel address.
#
# Android's NetD FLUSHES the nat POSTROUTING chain on a cellular re-init (APN
# cycle). If the routing module only reacts to rt_tables changes, it can miss
# that flush and the MASQUERADE never comes back -> hotspot clients can reach
# the tunnel but the provider drops them -> "VPN connected but no internet".
#
# This watchdog re-asserts the rule every 30s, but ONLY when tun0 exists and
# the rule is actually missing (zero-touch otherwise). It lives outside the
# routing module so a module update can't delete it.
#
# INSTALL (separate helper, not part of the lan-killswitch zip):
#   cp companion/vpn-gateway-watchdog.sh /data/adb/service.d/
#   chmod 755 /data/adb/service.d/vpn-gateway-watchdog.sh
# Debug log: touch /data/adb/vpn-gateway-watchdog.debug ; tail -f /data/adb/vpn-gateway-watchdog.log

DBG=/data/adb/vpn-gateway-watchdog.debug
LOG=/data/adb/vpn-gateway-watchdog.log
IPT=/system/bin/iptables
TUN=tun0
INTERVAL=30

setsid sh -c '
    DBG="'"$DBG"'"; LOG="'"$LOG"'"; IPT="'"$IPT"'"; TUN="'"$TUN"'"; INTERVAL='"$INTERVAL"'

    log() { [ -f "$DBG" ] && echo "[$(date +%F\ %T)] $*" >> "$LOG"; }

    while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
    log "watchdog active (interval ${INTERVAL}s)"

    while sleep "$INTERVAL"; do
        ip link show dev "$TUN" >/dev/null 2>&1 || continue
        if ! $IPT -w 2 -t nat -C POSTROUTING -o "$TUN" -j MASQUERADE 2>/dev/null; then
            $IPT -w 2 -t nat -I POSTROUTING 1 -o "$TUN" -j MASQUERADE \
                && log "MASQUERADE was missing on $TUN, re-inserted"
        fi
    done
' </dev/null >/dev/null 2>&1 &
disown 2>/dev/null
