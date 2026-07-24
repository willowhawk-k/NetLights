# NetLights — Release Notes

A live, layered map of your Mac's network interfaces. Free and open source (MIT),
shipped from one codebase through **two channels**: the **Mac App Store** and a
**Developer-ID / GitHub** download. NetLights has been live on the Mac App Store
since 1.6.3.

Future enhancements are listed first; the release history follows, newest at the top.

---

## Future enhancements

Backlog — not committed work, just where we're headed. Each carries a feasibility note.

### HDMI port + display capabilities
Detect whether the dedicated HDMI port has a display attached, identify it, and — stretch —
whether it supports features like eARC. Display *detection* via CoreGraphics is feasible;
mapping to the HDMI **port** and reading eARC/CEC capabilities is likely not exposed to apps
(same wall as USB-C per-port). Investigate.

### Per-device power draw on hover
Distinct from the system battery/charging already shipped: show each **USB peripheral's**
power draw (`bMaxPower` / negotiated current from the USB descriptor, via IOKit) and each
**Bluetooth device's** battery level (where reported) in the hover tooltips.

### Per-app traffic attribution (stretch)
Identify which apps are sending/receiving on a link, ideally with their icons. HARD:
per-process network attribution needs private frameworks (what `nettop` uses) and is not
available to a sandboxed app — may be infeasible without elevated access. App icons
themselves are easy (`NSWorkspace`/`NSRunningApplication`). Treat as research.

---

## Release history

### 1.8.0 — unreleased
- **See your VPN, end to end.** When a VPN is active, NetLights now traces the whole
  encrypted path as a distinct glowing tunnel — from the tunnel interface, through the
  physical carrier it actually egresses (per-tunnel, not always `en0`), across the
  Internet, out to a **far-side concentrator node** drawn beyond the Internet node.
  Hover any part for the tunnel, carrier, and server. The carrier and server IP are
  resolved from the routing table (the concentrator's pinned host route) — all
  in-process, no new permission.
- **Split tunneling made visible.** Traffic that bypasses the VPN — the public
  "excludes" that egress directly — is drawn as a separate **unencrypted (amber) strand**
  running alongside the encrypted pipe up the same carrier, then branching at the Internet
  to a **"Direct"** node. Encrypted-blue vs. plaintext-amber, side by side.
- **Routes tab, grouped.** The Routes table now groups into **Direct (split-tunnel)**,
  **Encrypted (VPN tunnel)**, and **Local** sections, each sorted by destination — with a
  one-click toggle back to a flat, numerically-sorted list.
- **Reveal your public IP (opt-in).** A new **Public IP** button looks up how the internet
  sees you — both the **exit** IP (through the VPN) and the **underlay** IP (your carrier's
  real address, bypassing the tunnel) — via a single on-demand STUN query. It is the app's
  only outbound connection, never automatic. See `PRIVACY.md`.
- **Cleaner trees.** Idle Thunderbolt / L2 **bridge** interfaces no longer clutter the
  "Hide inactive" view unless they're actually carrying traffic, and stacked
  device → port → gateway chains now curve gently instead of piling into one column.
- **Virtual adapters band.** VM/app virtual adapters (`en4`–`en6`) moved from the Physical
  band to the **Virtual** band where they belong (virtual L2, no hardware port); the band's
  OSI label is now **L2+**.
- Under the hood: the network model, pure transforms, and the graph-layout engine were
  lifted into a portable, Foundation-only core — groundwork for future platforms, with the
  macOS app behaving identically.

### 1.7.1 — 2026-07-18
- **External storage & Target Disk Mode on the map.** External drives now appear as
  storage chips on the Thunderbolt/USB port they're plugged into. A Mac connected in
  **Target Disk Mode** shows as a Mac chip with its disk nested beneath it (capacity,
  medium, and interconnect on hover) — so you can see a decommissioning target Mac and
  its drive right on the port. Read in-process from IOKit device metadata; no new
  permission, and never the volume's files.
- Attach/detach now shows within ~3s (was ~5s).

### 1.7.0 — 2026-07-08
- **iPhone / Thunderbolt bracket overlap fixed.** A hardware port now reserves layout
  width for its anchored interfaces' spread, not just its device-tree leaves — so an
  iPhone's USB-tether channels no longer overflow their slot and collide brackets with
  the neighbouring Thunderbolt port.
- **In-app feedback → GitHub issue.** A Help-menu item and an About-window link open a
  prefilled GitHub issue (app version + release channel, macOS version, and `hw.model`),
  making it easy to send bugs, ideas, and port-layout submissions for other Mac models.
- **DNS resolvers tab.** A new tab surfaces the resolvers name resolution actually uses:
  the active/global set (the "which DNS wins" answer) above a table of every network
  service's set — bound interface, resolver addresses, search domains, and split-DNS
  scoping. A VPN pushing its own resolvers over the physical uplinks' is plainly visible.
  All in-process via SCDynamicStore; privacy mode redacts resolver IPs and domains.

### 1.6.4 — 2026-07-03
- **Release-channel indicator.** About and the status bar note which build you're
  running — **App Store** or **GitHub** — alongside the version.
- The GitHub build now uses a distinct bundle id (`com.willowhawk.NetLights.gh`) so it
  can be installed side-by-side with the Mac App Store version.
- App Store build gains the Bluetooth capability so it can list connected devices.

### 1.6.3 — 2026-07-03
- 🎉 **Live on the Mac App Store.**
- **No more bracket overlap** on constrained windows: the Physical band reserves a strip
  for the TB-port bracket labels so interface tiles always sit below them.
- Layout-cache robustness fixes so tiles never render stale.

### 1.6.2 — 2026-07-02
- **Scrollable, natural-size canvas.** The graph keeps comfortable spacing and scrolls
  in both directions on smaller windows instead of compressing until tiles crowd.
- **Smoother** — layout is computed once per frame, so scrolling/resizing stays
  responsive on a busy graph.
- Vertical-overlap fixes (Data Link band, VPN gateway strip, USB device tree spacing).
- Added `SUPPORT.md`; the App Store build omits the in-app donation link per guideline
  3.1.1 (the GitHub build keeps the Sponsor link).

### 1.6.1 — 2026-06-30
- **Better device types** from USB interface descriptors + HID usage: mice, keyboards,
  game controllers/joysticks, speakers/headsets/mics, and webcams (previously generic
  "USB Device"). Same logic identifies Bluetooth-LE mice/keyboards.
- Device chips sort by **type, then name** at every tree level; clearer hub glyph.

### 1.6.0 — 2026-06-29
- **Bluetooth devices** appear under a new **Bluetooth** Hardware-row entity — type and,
  for input devices, **battery %** — behind an optional Bluetooth permission (read-only;
  never scans/pairs). Audio-device battery isn't available in-process.

### 1.5.0 — 2026-06-28
- **Live throughput on the wires** (↓/↑ bytes/sec, EMA-smoothed) and a **Link hover**
  with negotiated speed, live Down/Up, and byte totals.
- Switched to `NET_RT_IFLIST2` / `if_data64` so counters no longer wrap at 4 GiB and
  link speed isn't capped at ~4.3 Gbps.
- Anchored physical interfaces spread horizontally in one row (no overlap); TB bracket
  spans device-provided interfaces on the same receptacle.

### 1.4.2 — 2026-06-24
- **Battery entity** in the Hardware row — charge level and state (on battery / powered /
  charging), with adapter name + wattage on hover. Read from `AppleSmartBattery`,
  in-process and sandbox-safe.
- Mac App Store submission (build 8) — first sandboxed build submitted.

### 1.4.1 — 2026-06-24
- **System charging indicator** in the status bar (AC / charging + adapter wattage).
- Honest about power direction: macOS exposes no per-port USB-C direction, so charging
  is reported at the system level, never guessed onto a port.

### 1.4.0 — 2026-06-24
- **All device/display/Thunderbolt detection is now in-process** (IOKit + CoreGraphics)
  — no more `system_profiler` / `ioreg` subprocesses.
- **Mac App Store ready**: with no subprocesses, the app runs cleanly under the App
  Sandbox. No visible feature changes vs 1.3.1.

### 1.3.1 — 2026-06-14
- **Help ▸ Check Location Privacy Settings…** opens System Settings to Location Services
  (for showing the Wi-Fi SSID); greys out once access is granted.

### 1.3.0 — 2026-06-13
- **USB hub & dock hierarchy** — devices behind a hub nest as a tidy tree, each port
  owning its own non-overlapping region.
- **Devices tab** (manufacturer, bus, negotiated speed, USB class, VID:PID, port).
- **External display detection** under a Displays entity; richer hover tooltips.
- **Accurate Wi-Fi link speed** from CoreWLAN; content-sized layer bands.

### 1.2.0 — 2026-06-13
- **Reimagined topology** — Internet → gateways → devices → interfaces, top-down. The
  gateway sidebar is gone; gateways are chips pinned above their host.
- Hardware entities for everything upstream (Wi-Fi AP, MiFi/USB-Ethernet, iPhone).
- **Gateway precedence** driven by the macOS network service order (a "Svc order" column
  in Routes); the **dominant path glows**.

### 1.1.0 — 2026-06-11
- **Privacy mode** (toolbar) — masks IP and MAC addresses everywhere (graph, tooltips,
  tables), keeping the IPv4 first octet and MAC vendor OUI; leaves loopback/netmasks intact.

### 1.0 — 2026-06-11
- First release: the **layered OSI graph** (Hardware / Physical / Data Link / Virtual
  bands), **live link + traffic LEDs**, **hardware-port intelligence** (USB-C/TB
  attachment + charging badge), **iPhone → port linking**, the **VPN egress chain**,
  Routes / Interfaces tables, hover tooltips, and About / Help windows.
