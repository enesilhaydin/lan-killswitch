#!/system/bin/sh
# LAN Kill Switch - post-fs-data hook
# Installs an iptables FORWARD-chain interceptor that blocks traffic
# forwarded from tether/AP interfaces unless it's going out a tun*
# interface. Runs once at boot.

MODDIR=${0%/*}
LOG=/data/adb/lan-killswitch.log
IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
CONF="$MODDIR/interfaces.conf"
USER_CONF=/data/adb/lan-killswitch.interfaces

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Read interface list: user override wins, otherwise bundled defaults.
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

install_chain() {
    local ipt=$1
    local reject_with
    if [ "$ipt" = "$IPT" ]; then
        reject_with="icmp-net-unreachable"
    else
        reject_with="icmp6-no-route"
    fi

    $ipt -N lan_killswitch 2>/dev/null
    $ipt -F lan_killswitch
    $ipt -A lan_killswitch -o tun+ -j RETURN
    $ipt -A lan_killswitch -j REJECT --reject-with $reject_with
}

hook_interface() {
    local ipt=$1
    local iface=$2
    iface_exists "$iface" || return 0
    $ipt -C FORWARD -i "$iface" -j lan_killswitch 2>/dev/null \
        || $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
}

# Wait until iptables is usable (NetD finishes init)
( for i in $(seq 1 30); do
      $IPT -L FORWARD -n >/dev/null 2>&1 && break
      sleep 1
  done

  install_chain $IPT
  install_chain $IPT6

  load_interfaces | while read -r iface; do
      hook_interface $IPT  "$iface"
      hook_interface $IPT6 "$iface"
  done

  hooked=$(load_interfaces | while read -r i; do
      iface_exists "$i" && echo "$i"
  done | tr '\n' ' ')
  log "post-fs-data: chain installed, hooked: $hooked"
) &
