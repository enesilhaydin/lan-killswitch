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

A second hook (`service.sh`) runs after `boot_completed` as a watchdog:
it re-asserts the rules every 10 seconds **and** immediately on any link
change (via `ip monitor link`). This way:

- If another module flushes the FORWARD chain, we re-insert.
- If a new tether interface comes up later (e.g. user enables USB
  tethering hours after boot), we pick it up within seconds.
- **Top-position guarantee:** the watchdog does not just check that our
  hook *exists* — it checks that all our hooks sit at the very top of
  `FORWARD`. If another module (e.g. a VPN routing module) inserts an
  `ACCEPT` above us after boot, a single surviving hook could otherwise
  end up *below* it and be silently bypassed. When that drift is
  detected, the hooks are lifted back to the top without ever opening a
  leak gap (fresh copies inserted on top first, stale copies removed
  after).

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
- **IPv6**: covered (own ip6tables chain mirrors the v4 chain).

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

## Why not just use the existing module's REJECT?

Routing modules like `vpn-gateway` install their REJECT inside the same
`setup`/`cleanup` cycle as the rest of the tunnel rules. When the tunnel
goes down, `cleanup` removes **everything**, including the REJECT — i.e.
the safety net is removed exactly when you need it most. This module
exists *outside* that cycle so it can survive tunnel drops.

---

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

- [Kr328/vpn-gateway](https://github.com/Kr328/vpn-gateway) — the routing
  module that motivated this work. lan-killswitch is designed to sit
  alongside it (or any similar tethering-into-VPN gateway).
