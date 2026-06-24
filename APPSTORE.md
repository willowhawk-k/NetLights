# Mac App Store deployment

NetLights' data layer is now fully **in-process** (IOKit + CoreGraphics + sysctl +
SystemConfiguration + CoreWLAN) with **no `system_profiler`/`ioreg` subprocesses**,
so it runs cleanly under the **App Sandbox** the Mac App Store requires. This file
captures what's left to actually ship to the Store. (The Developer-ID GitHub channel
via `scripts/build-app.sh` is unchanged and keeps working in parallel.)

## What already works under the sandbox

Verified against `ioreg`/`system_profiler` ground truth on real hardware:

- Interfaces, addresses, routes, gateways, link state/speed — `getifaddrs` / `sysctl` / SystemConfiguration
- Wi-Fi link speed — CoreWLAN `transmitRate()` (no entitlement)
- Wi-Fi SSID — CoreWLAN `ssid()` + CoreLocation (needs the location entitlement, below)
- USB device tree, hub nesting, classification, vendor/VID:PID/speed/class — IOKit `IORegistryEntryCreateCFProperties`
- USB-C power / charger badge — IOKit `AppleHPMInterfaceType10`
- Thunderbolt receptacle mapping — IOKit `IOThunderboltSwitchType7`
- iPhone/iPad detection + BSD→port — IOKit registry
- External displays — CoreGraphics `CGGetActiveDisplayList` (maker/model labels are
  best-effort under sandbox; see `IOKitProbe.externalDisplays`)
- System charging (AC / adapter wattage) — IOKit `AppleSmartBattery`. Shown in the
  status bar. **Per-port power direction (which USB-C port delivers vs. receives
  power) is not exposed by macOS in either build** — verified against a known
  receiving+providing setup, the ports are byte-for-byte identical — so charging is
  reported system-wide, never pinned to a port. This is a macOS limitation, not a
  sandbox one.

## Entitlements

`NetLights.entitlements` (in repo root) — the minimal set:

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | Mandatory for the Mac App Store |
| `com.apple.security.network.client` | CoreWLAN / interface reads under sandbox |
| `com.apple.security.personal-information.location` | Unlocks the Wi-Fi SSID (CoreWLAN gates it behind Location) |

`com.apple.security.device.usb` is intentionally **omitted** — it only gates opening
USB *user clients*; NetLights merely reads IORegistry properties, which the sandbox
allows without it (verified empirically).

`Info.plist` already carries `NSLocationWhenInUseUsageDescription`.

## Steps to ship

SwiftPM alone can't produce an App Store upload, so wrap the sources in an Xcode app target:

1. **Xcode app target** — New → Project → macOS App ("NetLights"), bundle id
   `com.willowhawk.netlights`. Add all `Sources/NetLights/*.swift` to the target.
   (Or keep the SwiftPM package and add a thin app target that depends on it.)
2. **Signing** — Team = your Apple Developer account (`2KU2Y7CKHS`); enable
   "Automatically manage signing" → Xcode provisions the **Apple Distribution** cert
   + App Store provisioning profile.
3. **Entitlements** — set the target's "Code Signing Entitlements" to
   `NetLights.entitlements`. Confirm `NSLocationWhenInUseUsageDescription` is in the
   target's Info.plist.
4. **App Store Connect** — create the app record (Utilities category), add
   screenshots (reuse `assets/`), description, and the **Privacy "Nutrition Label"**:
   declare Location → *not linked to identity, not used for tracking*.
5. **Archive & upload** — Product → Archive → Distribute App → App Store Connect →
   Upload (or use Transporter).
6. **Submit for review** — human App Review, ~1–3 days. Free app.

## Known App Store trade-off

External-display **maker/model labels** degrade (e.g. "External Display" instead of
"LG ULTRAGEAR+") because the sandbox-safe `CGDisplayVendorNumber`/`NSScreen.localizedName`
don't carry the EDID strings that `system_profiler` parsed. Detection, resolution, and
refresh are unaffected. The Developer-ID build has the same in-process code, so the
behavior is identical across both channels.
