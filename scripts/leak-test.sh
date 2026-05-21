#!/usr/bin/env bash
# leak-test.sh — verify hotspot VPN integrity from a macOS client.
#
# Modes:
#   once          one-shot check: wait until ping responds, then probe
#   watch [N]     continuous probe every N seconds (default 5)
#   boot          adb reboot the phone, wait for ping, probe, report
#   handover      monitor while you toggle VPN on/off — must NEVER leak
#
# Leak signals we look for:
#   1. Public IPv4 owner contains TR-cellular ASN (Turk Telekom / Avea / Vodafone TR)
#   2. Public IPv6 reachable (should be blocked if your VPN doesn't tunnel v6)
#   3. DNS resolver outside the VPN's expected DNS
#   4. (optional) am.i.mullvad.net says mullvad_exit_ip: false
#
# Requires: curl, jq, dig. Install: `brew install jq bind` (dig is in bind).

set -u

# ---------- config ----------
PING_TARGET="${PING_TARGET:-1.1.1.1}"
IPINFO_V4="https://ipinfo.io/json"
IPINFO_V6="https://v6.ipinfo.io/json"
MULLVAD_CHECK="https://am.i.mullvad.net/json"
# Comma-separated substrings that mark a CELLULAR (leaked) provider.
# Match is case-insensitive against ipinfo's org/asn fields.
LEAK_MARKERS="${LEAK_MARKERS:-turk telekom,avea,vodafone tr,turkcell,as9121,as47331,as15897,as16135}"
# Optional: explicit cellular public IP your phone uses (if known). Set
# CELL_IP=10.60.141.86 etc. (CGNAT will hide this for you — usually leave empty.)
CELL_IP="${CELL_IP:-}"

# ---------- pretty ----------
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
else
    RED= GRN= YLW= CYA= RST=
fi
ok()  { echo "${GRN}[ OK ]${RST} $*"; }
bad() { echo "${RED}[FAIL]${RST} $*"; }
warn(){ echo "${YLW}[WARN]${RST} $*"; }
info(){ echo "${CYA}[INFO]${RST} $*"; }

# ---------- helpers ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1"; exit 1; }; }
need curl
need jq
command -v dig >/dev/null || warn "dig not found; DNS leak check will be skipped"

wait_for_ping() {
    local t=$PING_TARGET
    info "waiting for ping to $t ..."
    while ! ping -c1 -W2000 "$t" >/dev/null 2>&1; do
        printf "."
        sleep 1
    done
    echo
    ok "ping to $t responding"
}

probe_v4() {
    curl -s --max-time 5 "$IPINFO_V4" 2>/dev/null
}

probe_v6() {
    curl -s --max-time 5 "$IPINFO_V6" 2>/dev/null
}

probe_mullvad() {
    curl -s --max-time 5 "$MULLVAD_CHECK" 2>/dev/null
}

is_leak() {
    local org_lc=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    local IFS=,
    for m in $LEAK_MARKERS; do
        m=$(echo "$m" | xargs | tr '[:upper:]' '[:lower:]')
        [[ -z "$m" ]] && continue
        if [[ "$org_lc" == *"$m"* ]]; then return 0; fi
    done
    if [[ -n "$CELL_IP" && "$1" == *"$CELL_IP"* ]]; then return 0; fi
    return 1
}

dns_leak_check() {
    command -v dig >/dev/null || return 0
    # ECS-aware test: ask Google's DNS resolver who it thinks we are.
    local r
    r=$(dig +short TXT o-o.myaddr.l.google.com @ns1.google.com 2>/dev/null | tr -d '"' | head -1)
    [[ -z "$r" ]] && return 0
    info "DNS-perceived client IP: $r"
    local org=$(curl -s --max-time 5 "https://ipinfo.io/$r/json" | jq -r '.org // empty')
    if [[ -n "$org" ]]; then
        if is_leak "$org"; then
            bad "DNS leak — resolver sees you as: $org"
            return 1
        else
            ok "DNS path looks tunneled — $org"
        fi
    fi
    return 0
}

run_probe() {
    local fail=0
    local v4 v6 mv ip4_org ip4_ip ip6_ip ip6_org

    v4=$(probe_v4)
    if [[ -z "$v4" ]]; then
        warn "no IPv4 response from ipinfo (network down? or kill-switch firing — good if VPN is supposed to be off)"
    else
        ip4_ip=$(echo "$v4" | jq -r '.ip // "?"')
        ip4_org=$(echo "$v4" | jq -r '.org // "?"')
        local ip4_country=$(echo "$v4" | jq -r '.country // "?"')
        if is_leak "$ip4_org"; then
            bad "IPv4 LEAK: $ip4_ip ($ip4_org, $ip4_country)"
            fail=1
        else
            ok "IPv4 OK: $ip4_ip ($ip4_org, $ip4_country)"
        fi
    fi

    v6=$(probe_v6)
    if [[ -n "$v6" ]]; then
        ip6_ip=$(echo "$v6" | jq -r '.ip // "?"')
        ip6_org=$(echo "$v6" | jq -r '.org // "?"')
        if is_leak "$ip6_org"; then
            bad "IPv6 LEAK: $ip6_ip ($ip6_org)"
            fail=1
        else
            warn "IPv6 reachable: $ip6_ip ($ip6_org) — make sure your VPN tunnels v6, otherwise this might bypass it"
        fi
    fi

    mv=$(probe_mullvad)
    if [[ -n "$mv" ]]; then
        local m_exit=$(echo "$mv" | jq -r '.mullvad_exit_ip // false')
        if [[ "$m_exit" == "true" ]]; then
            ok "Mullvad confirms exit IP is theirs"
        else
            local m_org=$(echo "$mv" | jq -r '.organization // .org // "?"')
            warn "Mullvad says you are NOT exiting through them — $m_org (fine if you're using a different VPN)"
        fi
    fi

    dns_leak_check || fail=1
    return $fail
}

mode_once() {
    wait_for_ping
    run_probe
}

mode_watch() {
    local interval=${1:-5}
    local n=0
    while true; do
        n=$((n+1))
        echo "===== probe #$n  $(date '+%T') ====="
        run_probe || true
        sleep "$interval"
    done
}

mode_boot() {
    command -v adb >/dev/null || { echo "adb not in PATH"; exit 1; }
    info "rebooting phone via adb ..."
    adb reboot
    sleep 5
    wait_for_ping
    info "phone back, probing ..."
    run_probe
}

mode_handover() {
    info "handover test — toggle the VPN on/off from the phone."
    info "we'll probe every 2s and alert on any leak. Ctrl-C to stop."
    while true; do
        local out
        out=$(run_probe 2>&1)
        if echo "$out" | grep -q LEAK; then
            echo
            echo "$out"
            echo "${RED}!!!!! LEAK DETECTED at $(date '+%T') !!!!!${RST}"
            echo
        else
            printf "."
        fi
        sleep 2
    done
}

# ---------- dispatch ----------
case "${1:-once}" in
    once)     mode_once ;;
    watch)    mode_watch "${2:-5}" ;;
    boot)     mode_boot ;;
    handover) mode_handover ;;
    -h|--help|help)
        sed -n '2,15p' "$0" ;;
    *) echo "unknown mode: $1 (use: once | watch [N] | boot | handover)"; exit 2 ;;
esac
