# App Store — 1.9.5 (build 24)

Two paste-ready blocks. Lines are deliberately unwrapped — App Store Connect wraps text to
the field width, and hand-wrapping only creates breaks you have to undo.

---

## 1 · "What's New in This Version"

*Paste into App Store Connect → Version Information → What's New in This Version.*

```
Fixes the app slowing down the longer it stays open
If you left NetLights running for a day, clicks started to lag and the app used far more of your Mac's processor than it should. On macOS 26 a system framework leaked a little bookkeeping each time the view switcher at the top of the window redrew — and it redrew on every refresh, so each refresh cost a bit more than the last. The view switcher now redraws only when you change tabs. Response stays as quick on day three as at launch, and processor use drops to a fraction.
```

**Note for you, not for Apple:** one fix, so one paragraph. 1.9.4's notes are live and
approved; this only describes what 1.9.5 changes.

---

## 2 · App Review Notes

*Paste into App Store Connect → App Review Information → Notes. Field limit is 4,000
characters; this block is 3428.*

```
NetLights 1.9.5 (build 24), a bug-fix release. No new capabilities, entitlements or permission prompts compared with 1.9.4, approved 12 August 2026.

WHAT THE APP DOES
NetLights draws the machine's network interfaces as a layered map, lighting up live link, traffic, device and power state. It is read-only and needs no administrator rights.

ENTITLEMENTS (unchanged from the approved 1.9.4)
com.apple.security.app-sandbox — sandboxed.
com.apple.security.personal-information.location — macOS reveals the current Wi-Fi network name only to an app holding Location access, and NetLights uses it solely to label the Wi-Fi uplink. No location coordinates are read, stored or transmitted. Declining is fully supported; the uplink is then labelled simply "Wi-Fi".
com.apple.security.device.bluetooth — used solely to list ALREADY connected devices, so they can be drawn as attached hardware. The app never scans, pairs or connects. Declining is fully supported; the Bluetooth group then does not appear.
com.apple.security.network.client — a single outbound STUN query (RFC 5389, UDP) revealing the machine's public IP. It runs only when the user opens the "Public IP" button in the toolbar or presses Refresh in that popover — never automatically, never on launch. The app is otherwise entirely passive.

PRIVACY
No data is collected, stored off-device or transmitted. No analytics, accounts or third-party SDKs. App Privacy is declared "Data Not Collected". A Privacy toggle masks IP and MAC addresses throughout, for screenshots and screen-sharing.

IN THE PUBLIC SOURCE, BUT NOT IN THIS BUILD
NetLights is open source (MIT), built from one codebase for three targets: this sandboxed App Store build, a Developer-ID build, and a Linux build.
1. An HTTP server feature ("serve") showing the same graph in a browser is compiled out of this build by the APPSTORE build flag, because the sandbox has no incoming-connections entitlement. This build opens no listening sockets of any kind.
2. Linux-only hardware collectors, including a small D-Bus client that reads the Bluetooth device list on Linux, are each guarded by "#if os(Linux)" and are not compiled into this build. On macOS the Bluetooth list comes from IOBluetooth, gated by the entitlement above, exactly as in 1.9.4.

WHAT CHANGED IN THIS VERSION
One fix. The longer the app stayed open, the slower it responded and the more CPU it used. The cause was the view switcher at the top of the window: on macOS 26 the segmented control's framework bookkeeping was not released when the control redrew, and it redrew on every data refresh (every 0.75 seconds), so each refresh cost more than the last. The view switcher now redraws only when the user changes tabs. No UI, data source, entitlement or network behaviour changed.

OPTIONAL COMMAND-LINE INTERFACE
The same binary can also run as a terminal dashboard, not required and not surfaced in the app UI. Run /Applications/NetLights.app/Contents/Resources/netlights tui and press q. It opens no sockets and shows the same data as the window. The "serve" subcommand in the public documentation is not in this build.

WHERE TO LOOK
There is no new UI. Leave the app open for an hour or more: it should stay as responsive as at launch, and Activity Monitor should show it near idle between refreshes rather than holding a processor core.

Source and release notes: https://github.com/willowhawk-k/NetLights/releases/tag/v1.9.5
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

**Unchanged since 1.9.4** — re-paste only if the live listing was never updated with the
DNS tab and Privacy mode.

---

## Checklist before submitting

- [ ] Build **24** selected (must strictly exceed 23, which shipped as 1.9.4)
- [ ] Version string reads **1.9.5**
- [ ] "What's New" pasted from section 1
- [ ] App Review Notes pasted from section 2
- [ ] App Privacy still declared **Data Not Collected** — unchanged
- [ ] Description — unchanged
- [ ] Screenshots unchanged; no UI change in this release
