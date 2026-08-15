# NetLights on Linux

> **Status: collectors complete.** Every data source NetLights shows on macOS now has a
> Linux equivalent. What's left is the native desktop window and packaging. This page
> tracks what's real right now — not what's planned; the plan lives in
> [LINUX-PORT.md](LINUX-PORT.md).

There is **no published Linux release yet**, but the formats now exist and can be
[built locally](BUILDING.md#linux): a static **tarball**, zero-dependency **`.deb`** and
**`.rpm`**, and an **AppImage**, for both x86_64 and aarch64. AUR, the signed apt/yum
repositories, and the release itself are still to come.

All four formats are built and smoke-tested by CI on every tag, on both x86_64 and aarch64.
What has not happened yet is installing them on real hardware.

Once built, the tarball installs into any prefix:

```bash
tar -xzf netlights-<version>-<arch>.tar.gz
cd netlights-<version>-<arch> && ./install.sh ~/.local
```

`./install.sh` with no argument targets `/usr/local` and needs root. It copies files and
refreshes the desktop/icon caches; it never deletes anything, and prints the exact paths
to remove if you want it gone.

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

## Interoperability and acknowledgments

NetLights is MIT-licensed and has **no third-party code and no package dependencies** —
`Package.swift` declares none. Everything below is an *interface* NetLights talks to, not
code it contains, links, or ships.

| Project | How NetLights uses it | Relationship |
|---------|----------------------|--------------|
| **BlueZ** (GPL-2.0-or-later) | Bluetooth devices, via its documented D-Bus API (`org.bluez.Device1`, `org.bluez.Battery1`) | separate process, spoken to over a socket |
| **D-Bus** (freedesktop.org specification) | The wire protocol itself, implemented from the published spec | specification only — no `libdbus` |
| **systemd-resolved** (LGPL-2.1-or-later) | DNS resolvers past the local stub, from its files and `resolvectl` | files read; binary optionally invoked |
| **NetworkManager** (GPL-2.0-or-later) | Wi-Fi SSID fallback, via `nmcli` | binary optionally invoked |
| **`iw`** | Wi-Fi SSID and link rate | binary optionally invoked |
| **The Linux kernel** | Everything else — sysfs, procfs, netlink | public kernel interfaces |

Two clarifications worth stating plainly, because the code comments reference both:

**The D-Bus implementation is written from the specification**, not decompiled or copied.
BlueZ's D-Bus API is public and documented in BlueZ's own source tree precisely so that
third-party applications can use it — `bluetoothctl`, GNOME Settings and Blueman are all
D-Bus clients of the same interface. Nothing here is reverse-engineered.

**GLib was used as a verification oracle during development only.** The marshaller's output
was compared against GLib's independent D-Bus implementation to confirm byte-for-byte
agreement before shipping. No GLib code is in this repository and nothing links against it.

Every optional binary above degrades to absent: if `iw`, `nmcli` and `resolvectl` are all
missing, NetLights loses the SSID and some DNS attribution and keeps working.

Thanks to the BlueZ, systemd, NetworkManager and freedesktop.org maintainers, whose
documented, stable interfaces made a dependency-free port possible.

## Distributions

Targeted: **Ubuntu / Debian** (primary), **Mint**, **Fedora / RHEL / Rocky / Oracle
Linux**, **SUSE SLES**, **Arch**. The portability lever is a single fully-static musl
binary, so distro differences mostly disappear — see [BUILDING.md](BUILDING.md#linux).

Development and verification run on **Ubuntu arm64 under UTM**, with x86_64 built and
smoke-tested alongside it.
