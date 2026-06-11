#!/system/bin/sh
# diag.sh — two-shot internet-kill diagnostic for ZTE F50 VPN hotspot.
#
# USAGE (run as root on the device, or via: adb shell su -c "sh /sdcard/diag.sh up"):
#   1) RIGHT AFTER reboot, while internet still WORKS (first 20-60s):
#        sh diag.sh up
#   2) The MOMENT internet dies (hotspot has no net):
#        sh diag.sh down
#      -> this auto-prints the DIFF between the two snapshots.
#
#   Re-run "down" as many times as you like; it always diffs against the last "up".
#   "sh diag.sh diff" reprints the diff without collecting.
#   "sh diag.sh reset" clears saved snapshots.
#
# Raw dumps are kept under /data/local/tmp/lks-diag/ for manual inspection
# (pull with: adb pull /sdcard/lks-diag.tgz after running "sh diag.sh pack").

SNAPDIR=/data/local/tmp/lks-diag
mkdir -p "$SNAPDIR" 2>/dev/null

IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables

MODE="${1:-auto}"

# ---------- helpers ----------
KV=""          # path to key=value file for current run
RAW=""         # path to raw dump file for current run

kv()  { printf '%s=%s\n' "$1" "$2" >> "$KV"; }
raw() { printf '\n===== %s =====\n' "$1" >> "$RAW"; shift; "$@" >> "$RAW" 2>&1; }

collect() {
    KV="$SNAPDIR/$1.kv"
    RAW="$SNAPDIR/$1.raw"
    : > "$KV"
    : > "$RAW"

    # --- timing ---
    kv ts "$(date +%s)"
    kv time "$(date +%T)"
    kv uptime "$(cut -d' ' -f1 /proc/uptime)"

    # --- tun0 / VPN tunnel ---
    if ip link show dev tun0 >/dev/null 2>&1; then
        kv tun0_exists 1
        kv tun0_ip "$(ip -br addr show tun0 2>/dev/null | awk '{print $3}')"
        kv tun0_state "$(ip -br link show tun0 2>/dev/null | awk '{print $2}')"
        # RX/TX bytes — if internet is dead but TX keeps climbing while RX is
        # flat, the tunnel is sending into a black hole (handshake/route dead).
        set -- $(ip -s link show tun0 2>/dev/null | awk '/RX:/{getline; print $1, $2} /TX:/{getline; print $1, $2}')
        kv tun0_rx_bytes "$1"
        kv tun0_rx_pkts  "$2"
        kv tun0_tx_bytes "$3"
        kv tun0_tx_pkts  "$4"
    else
        kv tun0_exists 0
    fi

    # --- WireGuard endpoint reachability (THE classic killer) ---
    # If the route to the WG server endpoint goes via tun0 instead of the
    # cellular iface, you get a routing loop and the handshake dies after the
    # current keepalive window (20-60s). This is the #1 suspect for your symptom.
    EP=$(grep -h '^Endpoint' /data/data/com.wireguard.android/files/*.conf 2>/dev/null \
         | head -1 | sed 's/.*=[[:space:]]*//; s/:.*//')
    kv wg_endpoint "${EP:-unknown}"
    if [ -n "$EP" ]; then
        DEV=$(ip route get "$EP" 2>/dev/null | head -1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
        kv wg_endpoint_route_dev "${DEV:-none}"
        # Healthy = cellular (sipa_ethX / rmnet). BAD = tun0 (loop!).
        case "$DEV" in
            tun0) kv wg_endpoint_via_tunnel LOOP_BAD ;;
            "")   kv wg_endpoint_via_tunnel NO_ROUTE ;;
            *)    kv wg_endpoint_via_tunnel ok ;;
        esac
    fi

    # --- cellular ---
    kv cell_iface "$(ip -br addr show 2>/dev/null | awk '/sipa_eth[0-9]/ && /UP/{print $1; exit}')"
    kv cell_ip "$(ip -br addr show 2>/dev/null | awk '/sipa_eth[0-9]/{print $3; exit}')"
    kv default_route_main "$(ip route show table main 2>/dev/null | awk '/default/{print $3, $5; exit}')"
    kv ip_forward "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"

    # --- tun0 routing table ---
    kv tun0_table_default "$(ip route show table tun0 2>/dev/null | grep -c default)"

    # --- key ip rules ---
    kv rule_5050_tun0 "$(ip rule show 2>/dev/null | grep -c '192.168.0.0/16 lookup tun0')"
    kv rule_21000_br0_cell "$(ip rule show 2>/dev/null | grep -c '21000')"
    kv rule_14000_prohibit "$(ip rule show 2>/dev/null | grep -c 'prohibit')"

    # --- MASQUERADE ---
    kv masq_present "$($IPT -t nat -S POSTROUTING 2>/dev/null | grep -c 'o tun0 -j MASQUERADE')"
    set -- $($IPT -t nat -L POSTROUTING -nv 2>/dev/null | awk '/MASQUERADE/ && /tun0/{print $1, $2; exit}')
    kv masq_pkts "${1:-NA}"

    # --- lan_killswitch chain integrity ---
    kv lks_chain_exists "$($IPT -L lan_killswitch -n >/dev/null 2>&1 && echo 1 || echo 0)"
    kv lks_return_tun "$($IPT -S lan_killswitch 2>/dev/null | grep -c 'o tun+ -j RETURN')"
    kv lks_reject "$($IPT -S lan_killswitch 2>/dev/null | grep -c '\-j REJECT')"
    set -- $($IPT -L lan_killswitch -nv 2>/dev/null | awk '/REJECT/{print $1; exit}')
    kv lks_reject_pkts "${1:-NA}"
    set -- $($IPT -L lan_killswitch -nv 2>/dev/null | awk '/RETURN/ && /tun\+/{print $1; exit}')
    kv lks_return_pkts "${1:-NA}"

    # --- FORWARD ordering: is lan_killswitch ABOVE vpn-gateway accepts? ---
    kv fwd_hooks_v4 "$($IPT -S FORWARD 2>/dev/null | grep -c '\-j lan_killswitch')"
    kv fwd_first_rule "$($IPT -S FORWARD 2>/dev/null | grep '^-A FORWARD' | head -1)"
    # position (1-based) of the first lan_killswitch hook and the first tun0 ACCEPT
    kv fwd_pos_lks "$($IPT -S FORWARD 2>/dev/null | grep -n 'lan_killswitch' | head -1 | cut -d: -f1)"
    kv fwd_pos_tun_accept "$($IPT -S FORWARD 2>/dev/null | grep -n 'tun0 -j ACCEPT' | head -1 | cut -d: -f1)"

    # --- packet path simulation from a hotspot client ---
    kv route_hotspot_to_internet "$(ip route get 8.8.8.8 from 192.168.0.100 iif br0 2>/dev/null | head -1 | sed 's/  cache.*//')"

    # --- conntrack pressure ---
    kv conntrack_count "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)"
    kv conntrack_max "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"

    # --- processes ---
    kv vpn_gateway_procs "$(ps -ef | grep 'vpn-gateway/service' | grep -v grep | wc -l)"
    kv watchdog_procs "$(ps -ef | grep 'vpn-gateway-watchdog' | grep -v grep | wc -l)"
    kv lks_daemon_procs "$(ps -ef | grep 'lan-killswitch.log' | grep -v grep | wc -l)"
    kv wireguard_pid "$(ps -ef | grep 'com.wireguard' | grep -v grep | awk '{print $2}' | head -1)"
    kv ipmonitor_procs "$(ps -ef | grep 'ip monitor' | grep -v grep | wc -l)"

    # --- ordering-war evidence (how many times we re-lifted hooks) ---
    kv lks_lift_loglines "$(grep -c 'lifted hooks back to top' /data/adb/lan-killswitch.log 2>/dev/null)"
    kv lks_normalize_loglines "$(grep -c 'normalized FORWARD hook' /data/adb/lan-killswitch.log 2>/dev/null)"

    # --- thermal (throttle can drop modem) ---
    kv soc_temp "$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"

    # ===== RAW dumps (for manual inspection) =====
    raw "FORWARD v4"            $IPT -L FORWARD -nv --line-numbers
    raw "POSTROUTING nat"       $IPT -t nat -L POSTROUTING -nv --line-numbers
    raw "PREROUTING nat"        $IPT -t nat -L PREROUTING -nv --line-numbers
    raw "lan_killswitch v4"     $IPT -L lan_killswitch -nv
    raw "lan_killswitch v6"     $IPT6 -L lan_killswitch -nv
    raw "ip rule"               ip rule show
    raw "ip route main"         ip route show table main
    raw "ip route tun0"         ip route show table tun0
    raw "tun0 stats"            ip -s link show tun0
    raw "interfaces up"         ip -br addr show up
    raw "wg show"               sh -c 'wg show 2>/dev/null || echo "wg binary not present (userspace WG)"'
    raw "wireguard logcat"      sh -c 'logcat -d -t 150 2>/dev/null | grep -iE "wireguard|handshake|tun0|backend|GoBackend" | tail -25'
    raw "connectivity logcat"   sh -c 'logcat -d -t 200 2>/dev/null | grep -iE "captive|NetworkMonitor|validation|vpn" | tail -20'
    raw "dmesg net"             sh -c 'dmesg 2>/dev/null | tail -50 | grep -iE "rmnet|sipa|oom|killed|drop|thermal|throttl"'

    echo "[collected: $1]  tun0=$(grep '^tun0_exists=' "$KV"|cut -d= -f2)  endpoint_via=$(grep '^wg_endpoint_via_tunnel=' "$KV"|cut -d= -f2)  reject_pkts=$(grep '^lks_reject_pkts=' "$KV"|cut -d= -f2)"
}

diff_kv() {
    A="$SNAPDIR/up.kv"
    B="$SNAPDIR/down.kv"
    if [ ! -f "$A" ] || [ ! -f "$B" ]; then
        echo "Need both snapshots. Run 'sh diag.sh up' (net OK) then 'sh diag.sh down' (net dead)."
        return 1
    fi
    echo ""
    echo "=================== DIFF  up(net OK) -> down(net dead) ==================="
    awk -F= '
        NR==FNR { a[$1]=$2; next }
        {
            if ($1 in a) {
                if (a[$1] != $2) printf "CHANGED      %-26s  [%s] -> [%s]\n", $1, a[$1], $2
                delete a[$1]
            } else {
                printf "ONLY-IN-DOWN %-26s  %s\n", $1, $2
            }
        }
        END { for (k in a) printf "ONLY-IN-UP   %-26s  %s\n", k, a[k] }
    ' "$A" "$B" | sort
    echo ""
    echo "=================== VERDICT HINTS ==================="
    # auto-interpret the most diagnostic deltas
    upv()  { grep "^$1=" "$A" 2>/dev/null | cut -d= -f2-; }
    dnv()  { grep "^$1=" "$B" 2>/dev/null | cut -d= -f2-; }

    [ "$(dnv wg_endpoint_via_tunnel)" = "LOOP_BAD" ] && \
        echo "!! ROUTING LOOP: WG endpoint route goes via tun0 in DOWN state -> handshake can't refresh. PRIME SUSPECT (not lan-killswitch)."
    [ "$(upv cell_ip)" != "$(dnv cell_ip)" ] && \
        echo "!! CELLULAR IP CHANGED ($(upv cell_ip) -> $(dnv cell_ip)): APN cycle. tun0 endpoint route likely broke with it."
    [ "$(upv tun0_exists)" = "1" ] && [ "$(dnv tun0_exists)" = "0" ] && \
        echo "!! tun0 DISAPPEARED: WireGuard tunnel went down. Kill switch then correctly blocks LAN (working as intended)."
    if [ "$(upv tun0_exists)" = "1" ] && [ "$(dnv tun0_exists)" = "1" ]; then
        rxa=$(upv tun0_rx_pkts); rxb=$(dnv tun0_rx_pkts); txa=$(upv tun0_tx_pkts); txb=$(dnv tun0_tx_pkts)
        echo "   tun0 up in both. RX pkts $rxa->$rxb, TX pkts $txa->$txb."
        echo "   (TX climbing while RX flat = tunnel sending into black hole = endpoint/handshake dead.)"
    fi
    lifta=$(upv lks_lift_loglines); liftb=$(dnv lks_lift_loglines)
    if [ -n "$lifta" ] && [ -n "$liftb" ] && [ "$liftb" -gt "$lifta" ] 2>/dev/null; then
        d=$((liftb - lifta))
        echo "!! ORDERING WAR: lan-killswitch re-lifted hooks $d times between snapshots -> fighting vpn-gateway over FORWARD top slot."
    fi
    [ "$(dnv masq_present)" = "0" ] && [ "$(upv masq_present)" = "1" ] && \
        echo "!! MASQUERADE VANISHED: NAT rule gone in DOWN state -> Mullvad strict-NAT drops hotspot packets."
    [ "$(dnv lks_return_tun)" = "0" ] && \
        echo "!! lan_killswitch RETURN rule MISSING in DOWN: chain rejects EVERYTHING incl. tun0 traffic. lan-killswitch BUG confirmed."
    rpa=$(upv lks_reject_pkts); rpb=$(dnv lks_reject_pkts)
    if [ "$rpa" != "NA" ] && [ "$rpb" != "NA" ] && [ "$rpb" -gt "$rpa" ] 2>/dev/null; then
        echo "   lan_killswitch REJECT counter rose $rpa->$rpb (it IS dropping hotspot traffic — expected if tun0 is down)."
    fi
    echo "===================================================="
    echo "Raw dumps: $SNAPDIR/up.raw and $SNAPDIR/down.raw"
    echo "Bundle for pull:  sh diag.sh pack   ->  adb pull /sdcard/lks-diag.tgz"
}

case "$MODE" in
    up)
        collect up
        echo "UP snapshot saved. Now WAIT for internet to die, then run: sh diag.sh down"
        ;;
    down)
        collect down
        diff_kv
        ;;
    diff)
        diff_kv
        ;;
    pack)
        tar -czf /sdcard/lks-diag.tgz -C /data/local/tmp lks-diag 2>/dev/null
        echo "Packed -> /sdcard/lks-diag.tgz  (adb pull /sdcard/lks-diag.tgz)"
        ;;
    reset)
        rm -f "$SNAPDIR"/*.kv "$SNAPDIR"/*.raw
        echo "Snapshots cleared."
        ;;
    *)
        echo "Usage: sh diag.sh up | down | diff | pack | reset"
        echo "  up   : run while internet WORKS (just after reboot)"
        echo "  down : run when internet is DEAD (auto-prints diff)"
        ;;
esac
