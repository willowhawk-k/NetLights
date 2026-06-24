# Future enhancements & ideas

Backlog for NetLights — not committed work, just where we're headed. Rough order:
finish the power/battery work → Mac App Store release → iterate on the rest.

## Next: richer power state

macOS exposes battery + adapter state in-process via `AppleSmartBattery` (sandbox-safe),
verified on hardware:

- **Powered vs. powered & charging** — `ExternalConnected` (on AC), `IsCharging`,
  `FullyCharged`. Lets us show "Powered", "Powered & charging", or "On battery NN%"
  (distinguishing "plugged in but running off the adapter at 100%" from "actively charging").
- **Battery level** — `CurrentCapacity` (%).
- **Idea:** a **battery entity** in the graph with a charge-level + state indicator,
  instead of / in addition to the status-bar text.
- **Adapter wattage** — `AdapterDetails.Watts` (already shown in the status bar).
- **Adapter identity & wattage** — *resolved by hardware test.* We CANNOT distinguish the
  MagSafe port from a USB-C port: MagSafe 3 is electrically USB-C PD, so both report
  `Description="pd charger"`, `FamilyCode=0xE000000A`, and even `Name` says "USB-C Power
  Adapter". And there's no port attribution (per-port power direction is unexposed — see
  `APPSTORE.md`). BUT an *identified Apple adapter* exposes rich `AdapterDetails` —
  `Name` ("140W USB-C Power Adapter"), `Manufacturer` ("Apple Inc."), `Model`,
  `SerialString`, `Watts` — whereas a generic/dock PD source gives only `Watts`/voltage.
  So show the adapter's **name + wattage when known** (e.g. "On AC · 140W Apple adapter")
  — more useful than a MagSafe/USB-C label, and honest.

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

### Power levels on hover
Show USB device power draw (`bMaxPower` / current from the USB descriptor, via IOKit) and
Bluetooth device battery (where reported) in the hover tooltips.

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
