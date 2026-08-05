# NetLights on macOS

How the macOS build gets its data, and what it deliberately cannot tell you.
For the visual guide see [GUIDE.md](GUIDE.md); for the Linux port, [LINUX.md](LINUX.md).

NetLights is **read-only** and needs **no elevated privileges** — it never changes
configuration.

## Data sources

| Data | Source |
|------|--------|
| Interfaces & addresses | `getifaddrs()` |
| Link state, MAC, MTU, 64-bit rx/tx byte counters & baud | `sysctl(NET_RT_IFLIST2)` (`if_data64`) |
| Per-link throughput (↓/↑ rate) | computed from rx/tx counter deltas, EMA-smoothed |
| Routes & gateways | `sysctl(NET_RT_DUMP)` over `PF_ROUTE` |
| Friendly hardware-port names | SystemConfiguration (`SCNetworkInterface`) |
| Active + per-service DNS resolvers | SystemConfiguration (`SCDynamicStore`: `State:/Network/Global/DNS`, `.../Service/<id>/DNS`) |
| Thunderbolt receptacle status | IOKit `IOThunderboltSwitch` (in-process) |
| Attached devices, hub tree, iPhone port | IOKit `IOUSBHostDevice` registry (in-process) |
| USB-C attachment / charger badge | IOKit `AppleHPM` PD controller (in-process) |
| Device details (vendor, class, USB version, link speed) | IOKit registry properties |
| External displays | CoreGraphics `CGGetActiveDisplayList` |
| System charging (AC / wattage) | IOKit `AppleSmartBattery` (system-level, not per-port) |
| Wi-Fi link speed | CoreWLAN negotiated transmit rate |
| Connected Bluetooth devices | `IOBluetooth` paired-device list (needs Bluetooth permission) |
| Bluetooth HID battery | IOKit registry `BatteryPercent` (HID devices only; no audio battery) |

> **All in-process** as of 1.4 — no `system_profiler`/`ioreg` subprocesses — so NetLights
> runs under the App Sandbox. See [`../APPSTORE.md`](../APPSTORE.md).

## Capabilities & restrictions

- **No admin rights** — everything runs as your user, read-only.
- **Refresh cadence** — interface/route data every 0.75 s; the slower port-topology
  probe runs ~every 5 s on a background thread so the UI never stalls.
- **Link speed** — wired links read the interface's negotiated baud rate (64-bit via
  `NET_RT_IFLIST2`); Wi-Fi uses CoreWLAN's current transmit rate, which fluctuates as
  the radio adapts. The baud rate is what the driver reports and isn't always the full
  PHY rate (e.g. a Thunderbolt bridge advertises a nominal figure).
- **Throughput numbers** — derived from the kernel's rx/tx byte counters (now 64-bit,
  so they don't wrap mid-transfer), sampled each refresh and lightly smoothed. They
  reflect the interface's total traffic, which a per-app tool can't be derived from.
- **No route metric** — unlike Linux, macOS does not rank routes by a metric. Route
  selection is longest-prefix match, then the **network service order**, which is why
  the Routes table shows a *Svc order* column rather than a metric.
- **External displays** — detected and listed, but **not mapped to a specific port**:
  macOS doesn't expose which receptacle (or HDMI) a monitor uses to an unprivileged
  app, and no permission unlocks it. See [GUIDE.md](GUIDE.md#external-displays).
- **Port front/rear labels** — receptacle position labels come from a hand-curated
  per-model table and may be approximate on some Macs; connection/power state itself
  is read live and accurate.
- **Locked iPhone** — absent from the high-level USB device list, so NetLights reads
  the IOKit registry directly to find it.
- **Wi-Fi network name (Location)** — macOS only reveals the current SSID to apps
  with Location access, so NetLights requests it **solely to label the Wi-Fi
  uplink**. No location coordinates are ever read, stored, or shared; declining is
  fine (the uplink just shows "Wi-Fi"). The prompt only appears in the packaged
  app, not under `swift run`.
- **Bluetooth devices (permission)** — macOS gates the connected-device list behind
  Bluetooth access, so NetLights requests it **solely to list already-connected
  devices** (it never scans/pairs/connects). Decline and the Bluetooth entity just
  doesn't appear; like the SSID prompt, it only shows in the packaged app.
- **Bluetooth audio battery** — input-device battery is read from the IORegistry, but
  AirPods/headphone/speaker battery lives in the Bluetooth daemon (no in-process API),
  so it isn't shown.

## The two builds

NetLights ships from one codebase through two channels:

| | Mac App Store | Developer-ID / GitHub / Homebrew |
|---|---|---|
| Bundle id | `com.willowhawk.NetLights` | `com.willowhawk.NetLights.gh` |
| Sandboxed | yes | no (notarized, hardened runtime) |
| `netlights serve` | **no** — no incoming-connections entitlement | yes |
| `netlights tui` | yes | yes |
| Updates | App Store | `brew upgrade` / Releases |
| Sponsor link | omitted (guideline 3.1.1) | present |

The distinct bundle ids mean both can be installed side by side without Launch
Services confusing them — though only one can occupy `/Applications/NetLights.app`,
which is why the Homebrew cask refuses to install over an App Store copy.

## Command-line behaviour on macOS

A process started from a terminal is **attributed to the terminal**, not to the app.
macOS then refuses privacy-gated APIs on the terminal's behalf — and refusal is fatal,
not a denial: touching IOBluetooth in that state terminates the process. So the CLI
modes deliberately skip the Bluetooth and display-name probes. USB, Thunderbolt,
interfaces, routes and DNS all work normally.

Typing `netlights` with no arguments hands off to LaunchServices, so the window opens
as a properly-attributed app with the full device list.
