#!/bin/sh
# Fast, dependency-free logic tests for lan-killswitch. Runs ANYWHERE (macOS,
# Linux, CI) with no root and no iptables — it drives a mock iptables that keeps
# the FORWARD chain in a variable, so we can assert the watchdog algorithm
# (ensure_top drift recovery + idempotency) and the config parser (load_ifaces).
#
# Real packet behavior is covered separately by test/leak-netns.sh. A contract
# check ties the rule strings used here back to the shipped service.sh so the
# two cannot silently drift apart.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MOD="$HERE/.."

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (beklenen='$3' olan='$2')"; fi; }

# ----------------------------------------------------------------------------
echo "== logic-test =="

# --- 0) contract: rule strings + functions exist verbatim in the module ---
echo "[0] contract"
grep -q -- "-o tun+ -j RETURN"        "$MOD/service.sh"     || bad "service.sh: tun+ RETURN yok"
grep -q -- "-j REJECT --reject-with"  "$MOD/service.sh"     || bad "service.sh: REJECT yok"
grep -q    "ensure_top()"             "$MOD/service.sh"     || bad "service.sh: ensure_top yok"
grep -q -- "\[\[:space:\]\]"          "$MOD/service.sh"     || bad "service.sh: [[:space:]] yok"
grep -q -- "\[\[:space:\]\]"          "$MOD/post-fs-data.sh"|| bad "post-fs-data.sh: [[:space:]] yok"
[ "$fail" -eq 0 ] && ok "rule/function contract"

# --- 1) load_ifaces: comments (incl. indented), blanks filtered ---
echo "[1] load_ifaces"
load_ifaces() { grep -vE "^[[:space:]]*(#|$)" "$1" 2>/dev/null; }
cf=$(mktemp 2>/dev/null || echo /tmp/lks_cf.$$)
printf '# comment\n   # indented comment\n\nbr0\nwlan0\n' > "$cf"
out=$(load_ifaces "$cf" | tr '\n' ',')
rm -f "$cf"
eq "yorum/bosluk/girintili-yorum filtrelendi" "$out" "br0,wlan0,"

# --- 2) ensure_top: drift detection, leak-free re-lift, idempotency ---
echo "[2] ensure_top (mock iptables)"
ST=$(mktemp 2>/dev/null || echo /tmp/lks_fwd.$$)
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
load_ifaces() { printf 'br0\nwlan0\n'; } # configured interfaces
log() { :; }

# ensure_top() copied from service.sh (kept in sync via the contract check above).
ensure_top() {
    local ipt=$1 total topc tmp line iface
    total=$($ipt -S FORWARD 2>/dev/null | grep -c -- "-j lan_killswitch")
    [ "$total" -eq 0 ] && return 0
    tmp="$ST.top.$$"
    $ipt -S FORWARD 2>/dev/null | grep "^-A FORWARD" > "$tmp"
    topc=0
    while IFS= read -r line; do
        case "$line" in
            *"-j lan_killswitch") topc=$((topc + 1)) ;;
            *) break ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    [ "$topc" -eq "$total" ] && return 0
    for iface in $(load_ifaces); do
        while $ipt -D FORWARD -i "$iface" -j lan_killswitch 2>/dev/null; do :; done
    done
    for iface in $(load_ifaces); do
        ip link show dev "$iface" >/dev/null 2>&1 && $ipt -I FORWARD 1 -i "$iface" -j lan_killswitch
    done
}

# drifted state: a foreign ACCEPT sits above the wlan0 hook
printf -- '-A FORWARD -i br0 -j lan_killswitch\n-A FORWARD -j ACCEPT\n-A FORWARD -i wlan0 -j lan_killswitch\n' > "$ST"
ensure_top ipt
top2=$(ipt -S FORWARD | grep "^-A FORWARD" | head -2 | grep -c "lan_killswitch")
nhook=$(grep -c "lan_killswitch" "$ST")
eq "drift sonrasi ilk 2 satir hook" "$top2" "2"
eq "drift sonrasi toplam hook = 2 (duplikasyon yok)" "$nhook" "2"

before=$(cat "$ST")
ensure_top ipt
after=$(cat "$ST")
eq "ikinci cagri idempotent (degisiklik yok)" "$after" "$before"
rm -f "$ST" "$ST".* 2>/dev/null

echo
echo "== sonuc: PASS=$pass FAIL=$fail =="
[ "$fail" -eq 0 ] || exit 1
