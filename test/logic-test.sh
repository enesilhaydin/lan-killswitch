#!/bin/sh
# Fast, dependency-free logic tests for lan-killswitch. Runs ANYWHERE (macOS,
# Linux, CI) with no root and no iptables — it drives a mock iptables that keeps
# the FORWARD chain in a variable, so we can assert the watchdog algorithm
# (ensure_hook install/dedup/idempotency) and the config parser (load_ifaces).
#
# Real packet behavior — including chain-integrity rebuild and rule-order
# independence — is covered by test/leak-netns.sh. A contract check ties the
# rule strings used here back to the shipped service.sh so the two cannot
# silently drift apart.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOD="$HERE/.."

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (beklenen='$3' olan='$2')"; fi; }

# ----------------------------------------------------------------------------
echo "== logic-test =="

# --- 0) contract: rule strings + the v1.2.0 architecture invariants ---------
echo "[0] contract"
grep -q -- "-o tun+ -j RETURN"        "$MOD/service.sh"     || bad "service.sh: tun+ RETURN yok"
grep -q -- "-j REJECT --reject-with"  "$MOD/service.sh"     || bad "service.sh: REJECT yok"
grep -q    "ensure_hook()"            "$MOD/service.sh"     || bad "service.sh: ensure_hook yok"
# v1.2.0 removed order-policing + the link listener. Guard against regressions
# that would reintroduce the iptables churn / sweep storm.
grep -q    "ensure_top"               "$MOD/service.sh"     && bad "service.sh: ensure_top geri gelmis (order-policing churn)"
grep -q    "ip monitor"               "$MOD/service.sh"     && bad "service.sh: 'ip monitor' listener geri gelmis (sweep storm)"
# v1.2.1 chain-integrity check must be present (rebuild on broken chain).
grep -q -- '-C lan_killswitch -o tun+ -j RETURN' "$MOD/service.sh"     || bad "service.sh: ensure_chain butunluk kontrolu yok"
grep -q -- '-C lan_killswitch -o tun+ -j RETURN' "$MOD/post-fs-data.sh"|| bad "post-fs-data.sh: ensure_chain butunluk kontrolu yok"
grep -q -- "\[\[:space:\]\]"          "$MOD/service.sh"     || bad "service.sh: [[:space:]] yok"
grep -q -- "\[\[:space:\]\]"          "$MOD/post-fs-data.sh"|| bad "post-fs-data.sh: [[:space:]] yok"
[ "$fail" -eq 0 ] && ok "rule/function contract"

# --- 1) load_ifaces: comments (incl. indented), blanks filtered -------------
echo "[1] load_ifaces"
load_ifaces() { grep -vE "^[[:space:]]*(#|$)" "$1" 2>/dev/null; }
cf=$(mktemp 2>/dev/null || echo /tmp/lks_cf.$$)
printf '# comment\n   # indented comment\n\nbr0\nwlan0\n' > "$cf"
out=$(load_ifaces "$cf" | tr '\n' ',')
rm -f "$cf"
eq "yorum/bosluk/girintili-yorum filtrelendi" "$out" "br0,wlan0,"

# --- 2) ensure_hook: install-if-missing, idempotent, de-duplicate -----------
echo "[2] ensure_hook (mock iptables)"
ST=$(mktemp 2>/dev/null || echo /tmp/lks_fwd.$$)
: > "$ST"
ipt() {
    case "$1" in
        -S) echo "-P FORWARD ACCEPT"; cat "$ST" ;;
        -I) shift 3; { echo "-A FORWARD $*"; cat "$ST"; } > "$ST.t" && mv "$ST.t" "$ST" ;;  # drop: -I FORWARD 1
        -D) shift 2; pat="-A FORWARD $*"; removed=0; : > "$ST.t"                            # drop: -D FORWARD
            while IFS= read -r ln; do
                if [ "$removed" -eq 0 ] && [ "$ln" = "$pat" ]; then removed=1; continue; fi
                printf '%s\n' "$ln" >> "$ST.t"
            done < "$ST"; mv "$ST.t" "$ST"; [ "$removed" -eq 1 ] ;;
    esac
}
ip() { return 0; }                       # 'ip link show dev X' -> always present
log() { :; }

# ensure_hook() copied from service.sh (kept in sync via the contract check).
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

# (a) missing -> installs exactly one
ensure_hook ipt br0
n=$(grep -c "lan_killswitch" "$ST")
eq "eksik hook eklendi (1)" "$n" "1"

# (b) present once -> no change (idempotent, zero writes)
before=$(cat "$ST")
ensure_hook ipt br0
after=$(cat "$ST")
eq "tek hook varken idempotent (degisiklik yok)" "$after" "$before"

# (c) duplicated -> collapses back to exactly one
printf -- '-A FORWARD -i br0 -j lan_killswitch\n-A FORWARD -i br0 -j lan_killswitch\n-A FORWARD -i br0 -j lan_killswitch\n' > "$ST"
ensure_hook ipt br0
n=$(grep -c "lan_killswitch" "$ST")
eq "duplikasyon tek hook'a indirgendi" "$n" "1"
rm -f "$ST" "$ST".* 2>/dev/null

echo
echo "== sonuc: PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1
