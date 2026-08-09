# App Store — 1.9.3 (build 22)

Two sections below, each meant to be pasted whole into App Store Connect. Nothing here
describes features absent from the sandboxed build.

---

## 1 · "What's New in This Version"

*Paste into App Store Connect → Version Information → What's New in This Version.*

```
Graph layout fix
Machines with a lot of VPN tunnels could see the tunnel row's tiles overlap each other
in a narrow window. The graph now sizes itself to the widest row, so the tiles keep
their spacing and the view scrolls instead of crowding.

Routes: clearer column name
The "Svc order" column is now "Priority" — same value, plainer name. Lower still wins:
it's the network service order macOS uses to decide which default route carries traffic.

Terminal dashboard improvements (netlights tui)
The text dashboard gained a Hardware band, so a USB adapter and the network interface it
provides finally appear together, along with the hub or port each device hangs off. New
Port column in the Devices view; link up/down now uses distinct symbols rather than colour
alone, so it stays readable with colour turned off or when piped to a file; and the
Interfaces and Routes columns are wider so similarly-named interfaces no longer truncate
to the same text.

Under the hood
Device names that arrive from the hardware itself are now sanitised before they reach a
terminal, and the JSON snapshot (netlights --dump-json) gained the network service order.
```

**Notes for you, not for Apple:** this is deliberately short. The bulk of 1.9.3 was the
browser UI (`serve`) and the Linux port, and **neither ships in the App Store build** —
`serve` is compiled out by the sandbox, and the Linux collectors aren't macOS code. Padding
the release notes with either would describe software this build doesn't contain.

---

## 2 · App Review Notes

*Paste into App Store Connect → App Review Information → Notes.*

```
NetLights 1.9.3 (build 22). No new capabilities, entitlements, or permission prompts
compared with 1.9.2, which you approved on 5 August 2026.

WHAT THE APP DOES
NetLights draws the machine's network interfaces as a layered map — physical ports at the
top, virtual tunnels at the bottom — and lights up live link, traffic, device and power
state. It is entirely READ-ONLY: it never changes any network or system configuration, and
it requires no administrator rights.

ENTITLEMENTS — unchanged from the approved 1.9.2
  com.apple.security.app-sandbox                        sandboxed
  com.apple.security.personal-information.location      Wi-Fi network name only
  com.apple.security.device.bluetooth                   connected-device list only
  com.apple.security.network.client                     one on-demand outbound query

  Location is used for exactly one purpose: macOS only reveals the current Wi-Fi SSID to an
  app holding Location access, and NetLights uses it solely to label the Wi-Fi uplink in the
  graph. No location coordinates are read, stored, or transmitted. Declining is fully
  supported — the uplink is simply labelled "Wi-Fi".

  Bluetooth is used solely to list devices that are ALREADY connected, so they can be shown
  as attached hardware. The app never scans, pairs, or connects. Declining is fully
  supported — the Bluetooth group simply does not appear.

  Network client covers a single outbound STUN query (RFC 5389, UDP) used to reveal the
  machine's public IP address. It runs ONLY when the user opens the "Public IP" button in
  the toolbar, or presses Refresh inside that popover — never automatically, and never on
  launch. The app is otherwise entirely passive and makes no network requests of any kind.

PRIVACY
No data is collected, stored off-device, or transmitted. There are no analytics, no
accounts, and no third-party SDKs. App Privacy is declared as "Data Not Collected". A
Privacy toggle in the toolbar masks IP and MAC addresses throughout the interface for
screenshots and screen-sharing.

THINGS YOU MAY NOTICE IN THE SOURCE OR BINARY, AND WHY THEY ARE NOT ACTIVE HERE
NetLights is open source (MIT) and builds from one codebase for three targets: this
sandboxed App Store build, a Developer-ID build distributed outside the App Store, and a
Linux build. Two consequences are worth stating up front:

  1. The repository contains an HTTP server feature ("serve") that presents the same graph
     in a web browser. It is COMPILED OUT of this build by the APPSTORE build flag, because
     the sandbox has no incoming-connections entitlement. This build opens no listening
     sockets of any kind.

  2. The repository contains Linux-only hardware collectors, including a small D-Bus client
     used to read the Bluetooth device list on Linux. Every file in that collector is
     guarded by "#if os(Linux)" and none of it is compiled into this build. One portable
     support file compiles on macOS but has no macOS caller and is never invoked; the target
     enables dead-code stripping.

  On macOS the Bluetooth list comes from IOBluetooth, gated by the Bluetooth entitlement
  above, exactly as in the approved 1.9.2.

WHAT CHANGED IN THIS VERSION
  * A graph layout fix: with many VPN tunnels present, the tunnel row's tiles could overlap
    in a narrow window. The layout now sizes to the widest row.
  * The Routes tab's "Svc order" column is renamed "Priority".
  * Improvements to the optional terminal dashboard (see below).
  * Device names supplied by attached hardware are sanitised before being printed to a
    terminal, closing a terminal-escape-sequence injection path in the CLI.
  * The JSON snapshot gained the network service order (schema version 3, additive).

OPTIONAL COMMAND-LINE INTERFACE
The same binary can run as a terminal dashboard. It is not required and is not surfaced in
the app UI; it exists for users who prefer a terminal or work over SSH. To try it:

    /Applications/NetLights.app/Contents/Resources/netlights tui

Press q to quit. It opens no sockets and reads the same data the window shows. The
"serve" subcommand described in the public documentation is NOT present in this build.

HOW TO EXERCISE THE CHANGES
  * Launch the app. The Graph tab is the main view; Routes, Interfaces, Devices and DNS are
    tabs alongside it. The renamed "Priority" column is on the Routes tab.
  * The Privacy toggle is in the toolbar, next to the "Public IP" button.
  * The graph layout fix is most visible with several VPN tunnels active and a narrow
    window; without a VPN the graph is unchanged from 1.9.2.

CONTACT
Source, issue tracker and full release notes:
https://github.com/willowhawk-k/NetLights
Release notes for this version:
https://github.com/willowhawk-k/NetLights/releases/tag/v1.9.3
```

---

## Checklist before submitting

- [ ] Build **22** selected in App Store Connect (must strictly exceed 21, which shipped as 1.9.2)
- [ ] Version string reads **1.9.3**
- [ ] "What's New" pasted from section 1
- [ ] App Review Notes pasted from section 2
- [ ] App Privacy still declared **Data Not Collected** — unchanged
- [ ] No screenshot updates needed; the UI is visually unchanged apart from one column heading
