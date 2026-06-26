# Future enhancements & ideas

Backlog for NetLights — not committed work, just where we're headed.

## Shipped (for context — no longer backlog)

- **In-process IOKit/CoreGraphics rewrite** (1.4.0) — removed all `system_profiler`/`ioreg`
  subprocesses; App Sandbox–ready.
- **System power / charging** (1.4.1) — AC/charging state + adapter wattage in the status bar.
- **Battery entity** (1.4.2) — Hardware-row battery with charge level + state (on battery /
  powered / charging) and adapter name + wattage on hover.
- **MagSafe vs. USB-C — resolved (won't do):** hardware-tested that macOS exposes no per-port
  power direction (MagSafe 3 is electrically USB-C PD; both report `Description="pd charger"`,
  `FamilyCode=0xE000000A`). Identified Apple adapters do expose `Name`/`Watts`, which we show.
- **Mac App Store submission** (1.4.2, build 8) — sandboxed build submitted; see `APPSTORE.md`.

## Backlog

### Bluetooth devices ("Bluetooth is a kind of network")
Enumerate connected Bluetooth devices as a network class. `IOBluetooth` (App Store needs
the `com.apple.security.device.bluetooth` entitlement). Can surface device name/type, and
battery level for devices that report it.

### HDMI port + display capabilities
Detect whether the dedicated HDMI port has a display attached, identify it, and — stretch —
whether it supports features like eARC. Display *detection* via CoreGraphics is feasible;
mapping to the HDMI **port** and reading eARC/CEC capabilities is likely not exposed to apps
(same wall as USB-C per-port). Investigate.

### Per-device power draw on hover
Distinct from the system battery/charging already shipped: show each **USB peripheral's**
power draw (`bMaxPower` / negotiated current from the USB descriptor, via IOKit) and each
**Bluetooth device's** battery level (where reported) in the hover tooltips.

### Up/down traffic rate on links
We already sample per-interface `rx/tx` byte counters. Compute and show per-link throughput
(e.g. `↓ 12.3 / ↑ 1.1 MB/s`) on the connection lines and/or hover. Very feasible.

### Per-app traffic attribution (stretch)
Identify which apps are sending/receiving on a link, ideally with their icons. HARD:
per-process network attribution needs private frameworks (what `nettop` uses) and is not
available to a sandboxed app — may be infeasible without elevated access. App icons
themselves are easy (`NSWorkspace`/`NSRunningApplication`). Treat as research.

### In-app feedback → GitHub issues
A Help menu item / About button that opens a prefilled GitHub issue
(`github.com/willowhawk-k/NetLights/issues/new?title=…&body=…`) for bug reports, feedback,
and device-tree submissions from other Mac models. Can prefill `hw.model` + app version;
users attach screenshots in the browser. Easy, and high-value for crowdsourcing the
per-model port layouts in `InterfaceModel.swift`.
