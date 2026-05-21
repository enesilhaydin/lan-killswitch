#!/system/bin/sh
# LAN Kill Switch - service hook (late boot)
# Watchdog: re-asserts the chain + FORWARD hooks every 30s. Picks up new
# tether/AP interfaces that come up after boot (e.g. when the user turns
# on USB tethering hours later).

MODDIR=${0%/*}
LOG=/data/adb/lan-killswitch.log
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
CONF="$MODDIR/interfaces.conf"
USER_CONF=/data/adb/lan-killswitch.interfaces

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

load_interfaces() {
    local src
    if [ -f "$USER_CONF" ]; then
        src="$USER_CONF"
    else
        src="$CONF"
    fi
    grep -vE '^\s*(#|$)' "$src" 2>/dev/null
}

iface_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

ensure_chain() {
    local ipt=$1
    local reject_with
    [ "$ipt" = "$IPT" ] && reject_with="icmp-net-unreachable" || reject_with="icmp6-no-route"

    if ! $ipt -L lan_killswitch -n >/dev/null 2>&1; then
        $ipt -N lan_killswitch 2>/dev/null
        $ipt -F lan_killswitch
        $ipt -A lan_killswitch -o tun+ -j RETURN
        $ipt -A lan_killswitch -j REJECT --reject-with $reject_with
        log "re-created chain ($ipt)"
    fi
}

ensure_hook() {
    local ipt=$1
    local iface=$2
    iface_exists "$iface" || return 0
    if ! $ipt -C FORWARD -i "$iface" -j lan_killswitch 2>/dev/null; then
        $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
        log "re-inserted FORWARD hook on $iface ($ipt)"
    fi
}

( while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
  log "service: boot_completed, entering watchdog loop"

  while true; do
      ensure_chain $IPT
      ensure_chain $IPT6
      load_interfaces | while read -r iface; do
          ensure_hook $IPT  "$iface"
          ensure_hook $IPT6 "$iface"
      done
      sleep 30
  done
) &
