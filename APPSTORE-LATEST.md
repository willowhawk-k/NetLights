# App Store — 1.9.4 (build 23)

Two paste-ready blocks. Lines are deliberately unwrapped — App Store Connect wraps text to
the field width, and hand-wrapping only creates breaks you have to undo.

---

## 1 · "What's New in This Version"

*Paste into App Store Connect → Version Information → What's New in This Version.*

```
Shows the interface that actually reaches the internet
With Wi-Fi and Ethernet both connected, NetLights could name the wrong one as your primary uplink — a docked Mac might be told its traffic was leaving over Wi-Fi while it was really going out Ethernet. It now uses the same network service order macOS itself uses to decide, so the answer matches reality.

Link state now matches the system
An interface with no live link could still show as up — switched-off Wi-Fi, a Thunderbolt port with no cable, an idle bridge. NetLights was reading the interface's flags, which macOS leaves set in all of those cases; it now asks the system for the real link state. Your "interfaces up" count will drop and be accurate.

Clearer labelling of the primary
The status bar names the interface your internet traffic leaves through, and the Interfaces tab stars it. In the graph, that interface's tile is outlined and softly highlighted. On the Routes tab, only the default route that actually wins is starred — previously every default route was marked, which made it look like several were primary at once.
```

**Note for you, not for Apple:** short on purpose. 1.9.3's notes are already live and
approved, so this only describes what 1.9.4 changes.

---

## 2 · App Review Notes

*Paste into App Store Connect → App Review Information → Notes. Field limit is 4,000
characters; this block is sized to fit.*

```
NetLights 1.9.4 (build 23), a bug-fix release. No new capabilities, entitlements or permission prompts compared with 1.9.3, approved 10 August 2026.

WHAT THE APP DOES
NetLights draws the machine's network interfaces as a layered map, lighting up live link, traffic, device and power state. It is read-only and needs no administrator rights.

ENTITLEMENTS (unchanged from the approved 1.9.3)
com.apple.security.app-sandbox — sandboxed.
com.apple.security.personal-information.location — macOS reveals the current Wi-Fi network name only to an app holding Location access, and NetLights uses it solely to label the Wi-Fi uplink. No location coordinates are read, stored or transmitted. Declining is fully supported; the uplink is then labelled simply "Wi-Fi".
com.apple.security.device.bluetooth — used solely to list ALREADY connected devices, so they can be drawn as attached hardware. The app never scans, pairs or connects. Declining is fully supported; the Bluetooth group then does not appear.
com.apple.security.network.client — a single outbound STUN query (RFC 5389, UDP) revealing the machine's public IP. It runs only when the user opens the "Public IP" button in the toolbar or presses Refresh in that popover — never automatically, never on launch. The app is otherwise entirely passive.

PRIVACY
No data is collected, stored off-device or transmitted. No analytics, accounts or third-party SDKs. App Privacy is declared "Data Not Collected". A Privacy toggle masks IP and MAC addresses throughout, for screenshots and screen-sharing.

IN THE PUBLIC SOURCE, BUT NOT IN THIS BUILD
NetLights is open source (MIT), built from one codebase for three targets: this sandboxed App Store build, a Developer-ID build, and a Linux build.
1. An HTTP server feature ("serve") showing the same graph in a browser is compiled out of this build by the APPSTORE build flag, because the sandbox has no incoming-connections entitlement. This build opens no listening sockets of any kind.
2. Linux-only hardware collectors, including a small D-Bus client that reads the Bluetooth device list on Linux, are each guarded by "#if os(Linux)" and are not compiled into this build. One portable support file compiles on macOS but has no macOS caller and is never invoked. On macOS the Bluetooth list comes from IOBluetooth, gated by the entitlement above, exactly as in 1.9.3.

WHAT CHANGED IN THIS VERSION
Two user-visible bug fixes and the labelling around them. (1) NetLights identifies which interface carries traffic to the internet. With Wi-Fi and Ethernet both connected each holds a default route, and the app picked whichever the kernel listed first rather than the one macOS prefers, so it could name the wrong one. It now uses the network service order already shown in the Routes tab. (2) Link state was inferred from interface flags, which macOS leaves set on a Wi-Fi interface whose radio is off, so those read as up; it now uses SystemConfiguration's link state. Alongside those: the status bar names the primary interface, the Interfaces tab stars it, the graph highlights its tile, and the Routes tab stars only the winning default route rather than every one.

OPTIONAL COMMAND-LINE INTERFACE
The same binary can also run as a terminal dashboard, not required and not surfaced in the app UI. Run /Applications/NetLights.app/Contents/Resources/netlights tui and press q. It opens no sockets and shows the same data as the window. The "serve" subcommand in the public documentation is not in this build.

WHERE TO LOOK
The primary interface is named in the status bar at the bottom of the window, starred in the Interfaces tab, and outlined in the graph. Seeing the first fix requires two active uplinks — for example Wi-Fi connected while also plugged into Ethernet; the second is visible by switching Wi-Fi off.

Source and release notes: https://github.com/willowhawk-k/NetLights/releases/tag/v1.9.4
```

---

## 3 · App Store Description

*Paste into App Store Connect → Version Information → Description. This evolves with the
app rather than with each version — review it when a user-visible feature lands. Limit is
4,000 characters.*

```
NetLights turns your Mac's network into a live, layered map. Every interface — Wi-Fi, Ethernet, Thunderbolt, USB, VPN tunnels, loopback — is arranged into OSI-style bands, from the physical chassis ports at the top down to virtual tunnels at the bottom, with small LEDs showing live link and traffic.

• See the whole picture: ports, the Wi-Fi network, external displays, connected Bluetooth devices, and attached devices (iPhone/iPad, hubs, docks, drives, keyboards) — with USB hubs expanded into a tidy tree.
• Follow your traffic: live up/down throughput is drawn right on the links, and default gateways are ranked by precedence so you can see which uplink actually carries your packets.
• See your VPN end to end: the encrypted tunnel is drawn as a glowing pipe from your apps out to the far-side server, split-tunnel traffic that bypasses the VPN shows as a separate direct path, and the Routes tab groups routes into Direct, Encrypted and Local. Optionally reveal your public exit address alongside the underlay one.
• Know which DNS actually answers: the DNS tab shows the resolvers in use for every network service, marks the set that wins, and makes split-DNS scoping visible — so a VPN quietly pushing its own resolvers is obvious at a glance.
• Inspect anything: hover for details, or use the Routes, Interfaces, Devices and DNS tabs for full tables — manufacturer, negotiated link speed, USB class, vendor and product IDs, and which port each device sits on.
• Battery and power: a battery entity shows charge level and whether you are on battery, powered, or charging, with the adapter's name and wattage on hover.
• Privacy mode: one toggle masks every IP and MAC address across the graph and the tables while keeping the shape of your network readable — made for screenshots, screen-sharing and demos.
• Prefer a terminal? The app also includes an optional command-line dashboard that draws the same map as text, which works over SSH.

NetLights is read-only and needs no administrator rights — it never changes your configuration, collects no data, and runs entirely on your Mac. Its one optional outbound action is a "Public IP" button you can press to look up the address the internet sees for you, using a standard STUN query. Nothing else ever leaves your machine.

Free and open source under the MIT License — source at https://github.com/willowhawk-k/NetLights
```

**What changed vs. the description in APPSTORE.md:** added the **DNS tab** and **Privacy
mode**, both of which have shipped for several releases and were missing from the listing
entirely; added the optional terminal dashboard; and expanded the tables line to name the
columns. The rest is the previous wording.

---

## Checklist before submitting

- [ ] Build **23** selected (must strictly exceed 22, which shipped as 1.9.3)
- [ ] Version string reads **1.9.4**
- [ ] "What's New" pasted from section 1
- [ ] App Review Notes pasted from section 2
- [ ] App Privacy still declared **Data Not Collected** — unchanged
- [ ] Description — unchanged from 1.9.3; only re-paste if it was never updated with the DNS tab and Privacy mode (section 3)
- [ ] Screenshots unchanged; the UI gains a star and a highlight, nothing structural
