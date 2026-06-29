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
| `com.apple.security.device.bluetooth` | Read the connected-Bluetooth-device list (IOBluetooth) under sandbox |

`com.apple.security.device.usb` is intentionally **omitted** — it only gates opening
USB *user clients*; NetLights merely reads IORegistry properties, which the sandbox
allows without it (verified empirically).

`Info.plist` carries `NSLocationWhenInUseUsageDescription` and
`NSBluetoothAlwaysUsageDescription`. The Bluetooth string is **mandatory** even for
the Dev-ID build: touching any IOBluetooth API without it triggers an immediate TCC
privacy crash. `BluetoothProbe` only calls IOBluetooth when the string is present, so
`swift run` (no Info.plist key) safely runs with the feature off.

## Versioning (single source of truth)

`Version.xcconfig` (repo root) holds `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`,
and `NL_RELEASE_DATE`. Both channels read it: `build-app.sh` parses it, and the Xcode
target uses it as its base configuration (step C below). `AppInfo.swift` reads the
values back from the bundle's Info.plist at runtime, so the About screen always
matches. **Bump only `Version.xcconfig` per release.** Rule: `CURRENT_PROJECT_VERSION`
must strictly increase with each App Store upload (the first upload may reuse the
current build number; later ones must go up).

## Xcode walkthrough (first time — do this once)

SwiftPM can't produce an App Store upload, so we make a thin Xcode app target that
compiles the *same* `Sources/NetLights/*.swift` (no copies → one codebase).

**A. Create the project**
1. Xcode → File → New → Project → **macOS** → **App** → Next.
2. Product Name `NetLights`; Team = your Apple ID; Organization Identifier
   `com.willowhawk` (→ bundle id `com.willowhawk.netlights`); Interface **SwiftUI**;
   Language **Swift**; uncheck tests/Core Data.
3. Save it in a **new subfolder** of the repo: `~/Source/NetLights/app/`. **Uncheck
   "Create Git repository"** (the repo already exists).
4. In the new project, **delete the two template files** Xcode made — `NetLightsApp.swift`
   and `ContentView.swift` (right-click → Delete → Move to Trash). Ours replace them
   (there can be only one `@main`).
5. File → **Add Files to "NetLights"…** → go to `~/Source/NetLights/Sources/NetLights`
   → select **all** `.swift` files → **UNCHECK "Copy items if needed"** (critical — keeps
   one shared codebase) → "Create groups" → Add.

**B. Configure the target** (select the blue project → NetLights target)
6. **General** → Minimum Deployments → macOS **13.0**.
7. **Signing & Capabilities** → Team = yours, "Automatically manage signing" ✓,
   Bundle Identifier `com.willowhawk.netlights`. Click **+ Capability → App Sandbox**,
   then check **Network ▸ Outgoing Connections (Client)**, **App Data ▸ Location**, and
   **Hardware ▸ Bluetooth** (this matches `NetLights.entitlements`).
8. **Info** tab → add **Privacy – Location When In Use Usage Description** =
   *"NetLights uses your location only to read the current Wi-Fi network name (SSID),
   which macOS protects behind location access. No location coordinates are read,
   stored, or shared."* → add **Privacy – Bluetooth Always Usage Description** =
   *"NetLights uses Bluetooth only to list your already-connected Bluetooth devices
   (name, type, and battery where reported) in the graph. It never scans for, pairs
   with, or connects to anything."* → set **Application Category** = Utilities →
   (optional) add a row `NLReleaseDate` = `$(NL_RELEASE_DATE)`.

**C. Version single-source-of-truth**
9. Drag `~/Source/NetLights/Version.xcconfig` into the project navigator (uncheck Copy).
10. Select the **project** (not the target) → **Info** → **Configurations** → set both
    **Debug** and **Release** "Based on Configuration File" to **Version.xcconfig**.
11. Confirm target → General shows Version **1.4.2**, Build **8**. (If blank, set
    Version `$(MARKETING_VERSION)`, Build `$(CURRENT_PROJECT_VERSION)`.)

**D. App icon**
12. In the project's `Assets.xcassets`, delete the empty `AppIcon`, then drag in
    `~/Source/NetLights/assets/AppIcon.appiconset` (pre-built, all sizes incl. 1024).

**E. Build, then archive**
13. Scheme = "My Mac", Product → **Build** (⌘B) to confirm it compiles and runs.
    *(If you hit "library not found" linker errors, Build Phases → Link Binary With
    Libraries → add `CoreWLAN.framework` / `IOKit.framework` — usually auto-linked.)*
14. Product → **Archive** → **Distribute App** → **App Store Connect** → **Upload**.

## App Store Connect — create the app + paste this listing

Create the app in App Store Connect (Apps → + → New App; macOS; bundle id
`com.willowhawk.netlights`; SKU `netlights`), then fill in:

- **Name:** `NetLights: Map your ports!`  (the bare "NetLights" is reserved by
  another developer on the App Store; this unique name was accepted. The bundle id
  `com.willowhawk.netlights` and the in-app/Finder name "NetLights" are unaffected —
  the App Store listing name is allowed to differ.)
- **Subtitle (≤30):** `A live map of your network`
- **Category:** Utilities (secondary: Developer Tools, optional)
- **Promotional text (≤170):** See every network interface on your Mac as a live,
  layered map — Wi-Fi, Thunderbolt, USB, VPNs, gateways, and attached devices, all
  updating in real time.
- **Keywords (≤100):** `network,wifi,ethernet,thunderbolt,usb,vpn,gateway,ports,monitor,interface,lan,topology`
- **Support URL:** `https://github.com/willowhawk-k/NetLights`
- **Privacy Policy URL:** `https://github.com/willowhawk-k/NetLights/blob/main/PRIVACY.md`
- **Copyright:** `© 2026 Keith Willowhawk`
- **Age rating:** 4+
- **Description:**

> NetLights turns your Mac's network into a live, layered map. Every interface —
> Wi-Fi, Ethernet, Thunderbolt, USB, VPN tunnels, loopback — is arranged into
> OSI-style bands, from the physical chassis ports at the top down to virtual tunnels
> at the bottom, with small LEDs showing live link and traffic.
>
> • See the whole picture: ports, the Wi-Fi network, external displays, connected
> Bluetooth devices, and attached devices (iPhone/iPad, hubs, docks, drives, keyboards)
> — with USB hubs expanded into a tidy tree.
> • Follow your traffic: live up/down throughput is drawn right on the links, default
> gateways are ranked by precedence so you can see which uplink actually carries your
> packets, and VPN tunnels show where they egress.
> • Inspect anything: hover for details, or use the Routes, Interfaces, and Devices
> tabs for full tables (manufacturer, link speed, USB class, and more).
> • Battery & power: a battery entity shows charge level and whether you're on
> battery, powered, or charging.
>
> NetLights is read-only and needs no admin rights — it never changes your
> configuration. It collects no data and makes no network connections of its own;
> everything is read from your Mac and shown on your screen.
>
> Free and open source under the MIT License — source at
> https://github.com/willowhawk-k/NetLights

- **License Agreement:** Apple's **Standard License Agreement** (keep the default; do
  NOT fill the custom EULA field). The app is MIT-licensed — that governs the source
  on GitHub and is noted in the description above; the standard EULA covers the App
  Store binary. (A bare MIT custom EULA would fail Apple's minimum-terms requirement.)

## Privacy "nutrition label" answers

In App Store Connect → App Privacy:

- **Data collection:** choose **"No, we do not collect data from this app."** →
  results in **"Data Not Collected."** (NetLights stores/transmits nothing.)
- Location is used **on-device only** to read the SSID — it is *not* collected, so it
  is **not** declared as collected data. If App Review asks, the answer is: Location
  is requested solely to read the current Wi-Fi network name for the uplink label; no
  coordinates are read, stored, or transmitted (see the usage string + `PRIVACY.md`).
- Bluetooth is used **on-device only** to list already-connected devices (name, type,
  input-device battery) — *not* collected, *not* declared as collected data. NetLights
  never scans, pairs, or connects; it only reads the existing connected-device list.

## Screenshots

Mac App Store requires at least one, at **one** of these exact sizes (16:10):
`1280×800`, `1440×900`, `2560×1600`, or `2880×1800`. Recommended: **2560×1600**.

Capture 3–5 from the running app (resize/pad the `assets/` shots to an exact size, or
re-screenshot the window): the **graph** (hero), the **Devices** table, the **USB hub
tree**, and **Routes**/**Interfaces**. All must be real app UI.

## Known App Store trade-off

External-display **maker/model labels** degrade (e.g. "External Display" instead of
"LG ULTRAGEAR+") because the sandbox-safe `CGDisplayVendorNumber`/`NSScreen.localizedName`
don't carry the EDID strings that `system_profiler` parsed. Detection, resolution, and
refresh are unaffected. The Developer-ID build has the same in-process code, so the
behavior is identical across both channels.
