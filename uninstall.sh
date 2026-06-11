#!/system/bin/sh
# LAN Kill Switch - uninstall hook
# Runs when user removes the module via Magisk Manager.

IPT=/system/bin/iptables
IPT6=/system/bin/ip6tables
PIDFILE=/data/adb/lan-killswitch-endpoint-guard.pid

for ipt in $IPT $IPT6; do
    # Drop every FORWARD hook that targets our chain (across all interfaces)
    while $ipt -S FORWARD | grep -q "\-j lan_killswitch"; do
        rule=$($ipt -S FORWARD | grep -m1 "\-j lan_killswitch" | sed 's/^-A /-D /')
        $ipt $rule 2>/dev/null || break
    done
    $ipt -F lan_killswitch 2>/dev/null
    $ipt -X lan_killswitch 2>/dev/null
done

for dir in -o -i; do
    while $IPT -t mangle -D FORWARD $dir tun+ -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do : ; done
done
while $IPT -t nat -D POSTROUTING -o tun+ -j MASQUERADE 2>/dev/null; do : ; done

old=$(cat "$PIDFILE" 2>/dev/null)
[ -n "$old" ] && kill "$old" 2>/dev/null

rm -f  /data/adb/lan-killswitch.log
rm -f  /data/adb/lan-killswitch.debug
rm -f  /data/adb/lan-killswitch.allow-lan
rm -f  "$PIDFILE"
rm -rf /data/adb/lan-killswitch.lock
# Note: /data/adb/lan-killswitch.interfaces (user config) is intentionally kept.
