# lan-killswitch

**Tethering-aware VPN kill switch for rooted Android.**

A small Magisk module that prevents hotspot, USB-tether and Wi-Fi-AP clients
from reaching the internet whenever no VPN tunnel (`tun*`) is up. It closes
the gap left by Android's built-in *"Block connections without VPN"* toggle,
which only filters the device's own apps and does not cover forwarded
tethering traffic.

---

## Why this exists

Android ships with a system-level VPN kill switch:

> **Settings → Network & Internet → VPN → ⚙️ → Always-on VPN + Block
> connections without VPN**

That setting is **UID-based**. It uses `ip rule 14000 ... prohibit` and
related `bw_OUTPUT` rules to drop traffic from app UIDs when the VPN is
down. It works perfectly for apps running *on the device itself*.

It does **not** cover forwarded tethering traffic. Packets coming from a
phone, laptop or any other client connected to your hotspot are not bound
to an app UID — they pass through `tetherctrl_FORWARD` in the kernel's
`iptables` `FORWARD` chain. Android's lockdown logic does not insert any
REJECT rule there, by design.

The result: if you use a Magisk module like
[`vpn-gateway`](https://github.com/Kr328/vpn-gateway) to route hotspot
traffic into your WireGuard / Mullvad / OpenVPN tunnel, **the moment the
tunnel drops, hotspot clients leak straight out the cellular interface.**
The built-in kill switch does nothing about it.

This module plugs that hole.

---

## When you need this

| Scenario | Built-in "Block w/o VPN" enough? | Need lan-killswitch? |
|---|---|---|
| No VPN, no tethering | n/a | No |
| VPN on the device only, no tethering | ✅ Yes | No |
| Hotspot/tether, no VPN | n/a (you aren't routing through VPN) | No |
| **Hotspot/tether + VPN routed for clients** | ❌ No (leaks on tunnel drop) | **Yes** |

If your goal is "all hotspot traffic must go through the VPN, *or nothing
at all*", you need this module **alongside** your existing VPN routing
setup (e.g. `vpn-gateway`).

---

## How it works

On boot (`post-fs-data.sh`):

1. Creates a user-defined `iptables` chain called `lan_killswitch`:
   - `-o tun+ -j RETURN` &nbsp;(let packets going out any tunnel continue)
   - `-j REJECT --reject-with icmp-net-unreachable` &nbsp;(drop the rest)
2. Inserts a hook at the **top** of `FORWARD` for every configured
   interface (`br0`, `wlan0`, `usb0`, …): `-i <iface> -j lan_killswitch`.
3. Same for `ip6tables` with `icmp6-no-route`.

Because the hook sits at position 1, it intercepts traffic *before*
Android's `tetherctrl_FORWARD` chain can ACCEPT it. When no `tun*`
interface exists, every forwarded packet from a protected interface is
rejected.

A second hook (`service.sh`) runs after `boot_completed` as a passive watchdog:
it re-asserts the kill-switch hook on a slow cadence, only when the hook is
missing or duplicated. This way:

- If another module flushes the FORWARD chain, we re-insert.
- If a new tether interface comes up later (e.g. user enables USB
  tethering hours after boot), we pick it up on the next sweep.
- We avoid route/link event churn, so the module does not fight VPN routing
  helpers over iptables ordering.

Since v1.2.2, `service.sh` also starts `endpoint-guard.sh`. That guard fixes
the ZTE F50 / Mullvad failure where the WireGuard server endpoint itself
resolves through `tun0`; it pins the endpoint `/32` into the same policy table
via the cellular uplink, but only when the loop is actually detected.

Since v1.2.3, the watchdog also keeps two `mangle/FORWARD` TCPMSS clamp rules
alive for `tun+` forwarding. This fixes the case where IP connectivity works
but larger TCP flows such as web pages or speed tests intermittently hang
because the forwarded client keeps an MSS too large for the VPN path.

Since v1.2.4, the watchdog also keeps a single `nat/POSTROUTING -o tun+
-j MASQUERADE` rule alive. This is required by strict tunnel providers such as
Mullvad, which expect forwarded hotspot packets to use the tunnel address
instead of a LAN source like `192.168.0.x`.

Since v1.2.5, the same watchdog also supervises `endpoint-guard.sh`. If Android
kills that helper or its PID file goes stale, the next sweep starts it again so
the WireGuard endpoint route cannot quietly fall back into `tun0`.

The design is **independent of the VPN client lifecycle**. Whether the
tunnel is up, down, restarting, or never been started, the rule stays in
place. This is the key difference from putting the REJECT inside a VPN
routing module like `vpn-gateway`, where the rule lives and dies with the
tunnel — which is the opposite of what a kill switch should do.

---

## Installation

1. Download the latest release zip from the
   [Releases page](../../releases) (or zip the repo yourself).
2. Magisk Manager → **Modules** → **Install from storage** → pick the zip.
3. Reboot.
4. Verify:
   ```sh
   adb shell su -c 'iptables -L lan_killswitch -nv'
   adb shell su -c 'iptables -L FORWARD -nv --line-numbers | head'
   ```
   You should see the chain and the FORWARD hooks at the top.

To **disable** temporarily: Magisk Manager → Modules → toggle off → reboot.
To **uninstall**: Magisk Manager → Modules → remove → reboot. `uninstall.sh`
removes every hook and the chain.

---

## Configuration

By default, the module protects this interface list (only the ones that
actually exist on your device at scan time are hooked):

```
br0  wlan0  wlan1  wlan2  swlan0  ap0  rndis0  usb0  wlan_ap
```

These are the common tether/AP interface names across Android OEMs.

If your device uses a non-standard name, drop your own list at
**`/data/adb/lan-killswitch.interfaces`** — one interface per line, `#`
comments allowed. It overrides the bundled defaults. Example:

```
# my weird OEM
br_hotspot
wlan2
```

Check which interfaces are up while tethering is on:

```sh
adb shell su -c 'ip -br link show up'
```

No reboot needed — the watchdog picks up changes within 10 seconds.

### Local / intra-LAN traffic (opt-in)

By default the switch is **fully deny**: when no tunnel is up, *every*
forwarded packet from a protected interface is rejected — including
traffic forwarded between two local/tether interfaces (e.g. a Wi-Fi
client talking to a USB-tethered device).

Note this rarely matters in practice:

- Client ↔ phone (DHCP, DNS, gateway) is `INPUT`/`OUTPUT`, never
  `FORWARD` — it is **not** affected, so clients always keep their lease
  and can reach the phone.
- Client ↔ client on the *same* bridge/subnet is switched at L2 and
  never enters the IP `FORWARD` chain — also unaffected.
- Only *cross-interface* forwarding (different L3 segments) is cut.

If you want that cross-interface LAN traffic to keep flowing while the
tunnel is down (it is never an internet leak — it stays on the LAN),
opt in:

```sh
adb shell su -c 'touch /data/adb/lan-killswitch.allow-lan'
# revert to full deny:
adb shell su -c 'rm /data/adb/lan-killswitch.allow-lan'
```

The watchdog applies/removes the exception on its next sweep (≤10s); no
reboot needed. Internet egress stays rejected either way.

---

## Compatibility & testing notes

- **Tested**: ZTE F50 mobile hotspot (Android 13, Magisk rooted), with
  `vpn-gateway` routing hotspot LAN clients into a WireGuard tunnel
  (Mullvad and a self-hosted endpoint).
- **Requirements**: Magisk, `iptables` and `ip6tables` (standard on any
  rooted Android 9+).
- **No interaction with Android's Always-on VPN setting** — both can be
  on; they cover different traffic classes.
- **No `tun0` hardcoding** — `-o tun+` matches `tun0`, `tun1`, anything.
  Works with WireGuard userspace mode, kernel mode, OpenVPN, etc.
- **WireGuard endpoint loop guard**: v1.2.2 pins a looped IPv4 WireGuard
  endpoint route back to the cellular interface on ZTE-style policy routing.
- **TCP MSS clamp**: v1.2.3 clamps forwarded TCP SYNs on `tun+` paths to avoid
  MTU blackholes over full-tunnel hotspot VPN.
- **Tunnel MASQUERADE**: v1.2.4 keeps `-o tun+ -j MASQUERADE` present for
  strict providers such as Mullvad. It does not add APN/cellular NAT rules.
- **Endpoint guard supervision**: v1.2.5 restarts the WireGuard endpoint-loop
  helper if Android kills it after boot.
- **IPv6**: covered (own ip6tables chain mirrors the v4 chain).

### WireGuard scope

The core kill switch, TCP MSS clamp, and `tun+` MASQUERADE rules are generic for
VPN clients that expose a `tun*` interface. The endpoint-loop guard is
WireGuard-specific: it reads IPv4 `Endpoint = x.x.x.x:port` entries from the
WireGuard Android config directory and pins those endpoint routes if they loop
back through `tun*`. This release is designed and tested for the ZTE F50 +
WireGuard + Mullvad + `vpn-gateway` setup.

### Logs (off by default)

Since v1.1.3 the module is silent by default. To enable verbose logging
to `/data/adb/lan-killswitch.log`:

```sh
adb shell su -c 'touch /data/adb/lan-killswitch.debug'
# ... reproduce the issue ...
adb shell su -c 'tail -f /data/adb/lan-killswitch.log'
# When done:
adb shell su -c 'rm /data/adb/lan-killswitch.debug'
```

### Boot-trace (companion diagnostic, off by default)

If installed (`/data/adb/service.d/boot-trace.sh`), captures a per-boot
state snapshot every 5s for 5 min into
`/data/local/tmp/boot-traces/<timestamp>/` — useful for catching VPN /
hotspot / silent-reboot anomalies post-mortem.

```sh
adb shell su -c 'touch /data/adb/boot-trace.enable'   # arm before reboot
adb reboot
# ... after the boot you wanted to capture ...
adb shell su -c 'rm /data/adb/boot-trace.enable'       # disarm
adb shell su -c 'tar czf /sdcard/traces.tgz -C /data/local/tmp boot-traces'
adb pull /sdcard/traces.tgz
```

### Smoke test

With a client connected to the hotspot:

```sh
# VPN UP — should return your VPN exit IP
curl ifconfig.me

# Bring VPN down via the VPN app, then
curl ifconfig.me
# Should hang/timeout. iptables REJECT counter increments:
adb shell su -c 'iptables -L lan_killswitch -nv'
```

---

### Automated tests

Two layers, both run in CI (`.github/workflows/test.yml`) on every push:

- **`test/leak-netns.sh`** — *real packet* leak test. Builds a throwaway
  topology with Linux network namespaces (a client, a "cellular" egress,
  a "VPN" `tun0`), applies the exact rules the module ships, and sends
  real pings to assert: VPN-down → **rejected** (no leak), VPN-up →
  forwarded, `allow-lan` permits LAN-internal but **still** blocks
  internet, IPv6 parity, and that a foreign `ACCEPT` inserted above our
  hooks leaks until `ensure_top` re-lifts them. Needs root + Linux; from
  macOS/Windows just run it in Docker:

  ```sh
  sh test/run-in-docker.sh
  ```

- **`test/logic-test.sh`** — fast, no-root, no-iptables logic tests
  (mock iptables) for the watchdog drift recovery and the config parser.
  Runs anywhere:

  ```sh
  sh test/logic-test.sh
  ```

Both use a *contract check* that greps the rule strings out of
`service.sh`, so the tests cannot silently drift from the real module.
A `sh -n` pass over every script guards against the broken-quoting class
of bug inside the `setsid` blocks.

## Why the watchdog is passive (v1.2.0)

Earlier versions ran an aggressive watchdog: a 10s sweep **plus** an
`ip monitor link` listener, both of which policed rule *order* and re-lifted
the hook to the top of `FORWARD` whenever another module's rule appeared
above it. On a device also running a VPN routing module (vpn-gateway), this
turned into a tug-of-war over the top slot — constant `iptables -D/-I`
churn, high CPU, and brief windows where the kill switch was momentarily
removed during the delete-then-reinsert. The cure was worse than the
disease.

v1.2.0 makes the watchdog **passive**:

- **No order policing.** Hook position is irrelevant to correctness. Every
  vpn-gateway ACCEPT is qualified with `-o tun0` / `-i tun0`, so it only
  matches traffic that should pass while the VPN is up. With the VPN down,
  `tun0` has no route, those ACCEPTs can't match, and the packet still
  reaches our REJECT. Whether our hook is above or below them, the verdict
  is identical: **blocked when VPN down, allowed when VPN up.**
- **No link-event listener.** The `ip monitor` sweep storm is gone.
- **Slow 60s cadence, zero-write steady state.** The watchdog only writes to
  iptables when a hook is genuinely *missing* or *duplicated*. If everything
  is in place (the normal case), it performs read-only checks and touches
  nothing — so it can't destabilise the network.

The FORWARD hook is installed once at boot (`post-fs-data` + 90s retry) and,
in practice, never disappears afterward: NetD does not flush custom-chain
jumps in `FORWARD`, and vpn-gateway only adds rules, never removes ours. The
60s watchdog is just a cheap safety net for the rare exception.

> Note: the MASQUERADE rule a VPN routing module needs *does* get flushed by
> NetD on cellular re-init (APN cycle), but that is the routing module's
> concern, not this kill switch's. Keep that rule under its own watchdog.

## Why not just use the existing module's REJECT?

Routing modules like `vpn-gateway` install their REJECT inside the same
`setup`/`cleanup` cycle as the rest of the tunnel rules. When the tunnel
goes down, `cleanup` removes **everything**, including the REJECT — i.e.
the safety net is removed exactly when you need it most. This module
exists *outside* that cycle so it can survive tunnel drops.

---

## Companion helpers (optional, VPN routing layer)

The kill switch protects the *tether* path. Some faults live in the *VPN
routing* layer and look like "the hotspot broke." v1.2.2 now includes the
WireGuard endpoint-loop guard directly, v1.2.4 includes the `tun+`
MASQUERADE keepalive directly, and v1.2.5 supervises the endpoint guard from
the main watchdog. The standalone helpers under
[`companion/`](companion/) are kept for older installs and diagnostics:

| Helper | Fixes |
|---|---|
| `endpoint-guard.sh` | Built into the module since v1.2.2. Hotspot works ~20-60s after connecting then **dies** because the WireGuard server endpoint route loops back through `tun0`. |
| `vpn-gateway-watchdog.sh` | Older standalone copy of the v1.2.4 built-in MASQUERADE keepalive. VPN connected but hotspot has **no internet** after NetD flushes the `tun0` MASQUERADE rule. |

Both are zero-touch when healthy and safe-fail (do nothing if they can't act
safely). Install the MASQUERADE helper per
[`companion/README.md`](companion/README.md) only if you need it.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- [Kr328/vpn-gateway](https://github.com/Kr328/vpn-gateway) — the routing
  module that motivated this work. lan-killswitch is designed to sit
  alongside it (or any similar tethering-into-VPN gateway).
