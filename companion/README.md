# companion helpers

These are **optional** `/data/adb/service.d/` scripts that solve problems in
the *VPN routing* layer. They are **not** part of the lan-killswitch Magisk
module and are **not** in the release zip — the kill switch works without them.
Install them only if you hit the specific symptom each one addresses.

Both are **safe**: they act only when a fault is actually present, do nothing
when healthy, and never guess in a way that could blackhole traffic.

| Script | Symptom it fixes |
|---|---|
| `vpn-endpoint-guard.sh` | Hotspot internet works ~20-60s after connecting, then **dies permanently** (VPN routing-loop on the WG endpoint). |
| `vpn-gateway-watchdog.sh` | VPN shows connected but hotspot has **no internet at all**, often after an APN cycle (MASQUERADE flushed by NetD). |

## vpn-endpoint-guard.sh

WireGuard's default route is `0.0.0.0/0 dev tun0`. The encrypted handshake /
keepalive packets to the WG **server endpoint** must leave via the **cellular**
uplink. If the route to the endpoint instead resolves via `tun0`, those packets
loop back into the tunnel, the handshake can't refresh, and after the
`PersistentKeepalive` window (~20-60s) the tunnel dies.

The guard checks each WG server endpoint's route every 20s **only while a tun\*
is up**. If an endpoint routes via `tun*` (a loop), it pins a `/32` host route
to that endpoint via the cellular uplink. If it can't identify the cellular
uplink, it does nothing (safe-fail).

Confirm you have this problem first:
```sh
adb push scripts/diag.sh /sdcard/diag.sh
adb shell su -c "sh /sdcard/diag.sh up"     # while internet works
adb shell su -c "sh /sdcard/diag.sh down"   # when it dies
# look for: wg_endpoint_via_tunnel=LOOP_BAD
```

## vpn-gateway-watchdog.sh

Re-asserts the `POSTROUTING -o tun0 -j MASQUERADE` rule (needed by strict-NAT
providers like Mullvad) every 30s, but only when `tun0` exists and the rule is
missing. NetD flushes the nat table on cellular re-init; this puts it back.

## Install

```sh
adb push companion/vpn-endpoint-guard.sh   /sdcard/
adb push companion/vpn-gateway-watchdog.sh /sdcard/
adb shell su -c '
  cp /sdcard/vpn-endpoint-guard.sh   /data/adb/service.d/
  cp /sdcard/vpn-gateway-watchdog.sh /data/adb/service.d/
  chmod 755 /data/adb/service.d/vpn-endpoint-guard.sh /data/adb/service.d/vpn-gateway-watchdog.sh
  chown root:root /data/adb/service.d/vpn-endpoint-guard.sh /data/adb/service.d/vpn-gateway-watchdog.sh
  rm /sdcard/vpn-endpoint-guard.sh /sdcard/vpn-gateway-watchdog.sh
'
```

They start on the next boot, or run them by hand once:
```sh
adb shell su -c 'sh /data/adb/service.d/vpn-endpoint-guard.sh'
adb shell su -c 'sh /data/adb/service.d/vpn-gateway-watchdog.sh'
```

Enable debug logging per script:
```sh
adb shell su -c 'touch /data/adb/vpn-endpoint-guard.debug'
adb shell su -c 'touch /data/adb/vpn-gateway-watchdog.debug'
```
