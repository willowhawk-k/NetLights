# NetLights on Linux

> **Status: collectors complete.** Every data source NetLights shows on macOS now has a
> Linux equivalent. What's left is the native desktop window and packaging. This page
> tracks what's real right now — not what's planned; the plan lives in
> [LINUX-PORT.md](LINUX-PORT.md).

There is **no packaged Linux release yet** — no `.deb`, `.rpm`, AppImage or AUR
package. Until then, [build from source](BUILDING.md#linux).

## What works today

```bash
netlights tui        # live full-screen dashboard in the terminal
netlights serve      # the same graph in your browser
netlights --dump-json
```

`serve` and `tui` are the same code paths the macOS build uses — the graph geometry,
the SVG renderer, the terminal renderer and the CLI grammar all live in the shared
core, so a Linux box and a Mac render the same snapshot identically.

Running `netlights` with no arguments starts `serve` (macOS opens the app window
instead — there is no window on Linux yet).

## Collector status

| Data | Status | Source |
|------|--------|--------|
| Interfaces, addresses, MAC, MTU, flags | ✅ works | `getifaddrs` + `/sys/class/net/<if>/*` |
| Link speed & carrier | ✅ works | `/sys/class/net/<if>/{speed,carrier,operstate}` |
| Traffic counters & live rates | ✅ works | `/sys/class/net/<if>/statistics/*_bytes` |
| Routes & gateway precedence | ✅ works | `/proc/net/route`, `/proc/net/ipv6_route` |
| DNS resolvers (past the stub) | ✅ works | see [DNS](#dns) below |
| Machine model | ✅ works | `/sys/devices/virtual/dmi/id/product_name` |
| Route metric (Priority column) | ✅ works | `/proc/net/route` field 6 |
| USB device tree (hubs, nesting, adapters) | ✅ works | `/sys/bus/usb/devices` |
| Displays + EDID | ✅ works | `/sys/class/drm/*/edid` — see below |
| Battery / power | ✅ works | `/sys/class/power_supply/*` |
| Wi-Fi SSID / link rate | ✅ works | `iw` or `nmcli` — degrades if absent |
| Thunderbolt | ✅ works | `/sys/bus/thunderbolt/devices` |
| Bluetooth devices | ✅ works | BlueZ over D-Bus — see below |
| Native desktop window | ⏳ not yet | WebKitGTK |

Everything is **read-only** and needs no elevated privileges, same as macOS. Collectors
that can't run **degrade to absent** — a missing Wi-Fi or Bluetooth source never blocks
the rest of the graph.

## DNS

This is where Linux is currently *better* than the sandboxed Mac build.

On any systemd-resolved system `/etc/resolv.conf` is a symlink to the **stub** file,
holding `127.0.0.53` — a loopback address that tells you nothing about who actually
answers your queries. Every tool on the box dutifully reports it. NetLights answers the
question you were really asking: **what is past the stub?**

It reads, in order of usefulness:

| Source | What it adds |
|--------|--------------|
| `/run/systemd/resolve/resolv.conf` | the real upstream servers (**not** `stub-resolv.conf`) |
| `resolvectl status` | per-link attribution + which server is *currently in use* |
| `/run/NetworkManager/resolv.conf` | the same idea on NetworkManager without resolved |
| `/etc/resolv.conf` | last resort; usually the stub |

The DNS tab then shows an **Active resolvers** banner (the real upstreams), a row per
**link** — which interface learned which servers, and the one resolved is actually
querying — and, when the system is behind a stub, the stub itself, clearly labelled.
Keeping the stub visible is deliberate: it *is* what the C library talks to, and showing
it explains why everything else on the machine says `127.0.0.53`.

None of this needs D-Bus, so it works in the fully static musl build. On a
non-systemd distro `resolvectl` is simply absent and the file sources carry it.

## Displays — richer than macOS

A sandboxed macOS app gets a monitor's vendor id, resolution and refresh, but never its
model name. Linux hands over the raw EDID, so NetLights shows the **actual product name**
(`CU34G2XP`, not "AOC Display"), and reads the high-refresh modes out of the CTA-861
extension block rather than believing the conservative timing in the base block.

One caveat worth knowing: the label is the best mode the display **declares**, not the mode
it is currently **running**. macOS reports the running mode. On a monitor whose top rate is
reached through adaptive-sync rather than a declared timing, the two can differ — the
developer's own 180 Hz panel declares 100 Hz as its fastest detailed timing. Reading the
live mode needs a libdrm ioctl, which the static build deliberately avoids.

## Bluetooth without libdbus

BlueZ is reachable only over D-Bus, and linking `libdbus` would forfeit the single static
binary that the whole distribution plan rests on. So NetLights **speaks D-Bus itself** —
about 400 lines of Foundation-only code implementing the SASL EXTERNAL handshake, the
message header, the alignment rules for every type involved, and the
`GetManagedObjects` call. No dependency, and the binary stays `statically linked`.

The marshaller was cross-checked against GLib's independent implementation for
byte-identical output before it shipped.

Devices are selected by the presence of the `org.bluez.Device1` **interface**, never by the
shape of the object path — a single connected LE peripheral contributes 50–150 GATT child
objects that all live beneath its own path. Battery arrives on the same object as a sibling
`org.bluez.Battery1` interface, which is *more* reliable than the macOS path (that one has
to join an IORegistry entry against the Bluetooth address).

Classification handles both worlds: Classic devices carry a Class-of-Device that feeds the
same classifier macOS uses, while BLE-only devices have no Class at all and are resolved
from their GAP Appearance, then BlueZ's derived icon.

## Known differences from macOS

- **Route metric vs service order** — Linux ranks routes by metric; macOS has no metric and
  ranks by network-service order. Both now appear in a single **Priority** column, since a
  platform only ever has one of them. Lower wins either way.
- **Duplicate-looking routes** — the kernel legitimately lists several entries for one
  interface. With the Priority column visible this is usually self-explanatory: two default
  routes over one interface differing only by metric (say 100 from one DHCP config and 1024
  from another) are no longer indistinguishable.
- **Ports are USB buses, not receptacles** — macOS has a hand-curated per-model table giving
  each Thunderbolt port a side and position. A generic PC exposes no such data to an
  unprivileged process, so the Hardware band groups devices by **USB bus** ("USB Bus 1")
  rather than pretending to know which physical hole they're in. Note an xHCI controller
  registers its USB2 and USB3 root hubs as separate buses, so the same socket can appear as
  a different bus depending on what you plug into it.
- **Connected-but-unpaired Bluetooth devices appear on Linux** and not on macOS. That's not
  a bug in either: macOS enumerates *paired* devices and filters by connected because
  IOBluetooth offers no connected-device list, whereas BlueZ answers the question directly.
  A GATT-connected peripheral with no bond is genuinely attached.
- **No Location gate on the SSID** — Linux needs no permission prompt for the network name,
  but it does need `iw` (or NetworkManager) present; a minimal server install may have
  neither, in which case the SSID is simply absent.

## Distributions

Targeted: **Ubuntu / Debian** (primary), **Mint**, **Fedora / RHEL / Rocky / Oracle
Linux**, **SUSE SLES**, **Arch**. The portability lever is a single fully-static musl
binary, so distro differences mostly disappear — see [BUILDING.md](BUILDING.md#linux).

Development and verification run on **Ubuntu arm64 under UTM**, with x86_64 built and
smoke-tested alongside it.
