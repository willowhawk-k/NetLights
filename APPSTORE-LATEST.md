# App Store — 1.9.3 (build 22)

Two paste-ready blocks. Lines are deliberately unwrapped — App Store Connect wraps text to
the field width, and hand-wrapping only creates breaks you have to undo.

---

## 1 · "What's New in This Version"

*Paste into App Store Connect → Version Information → What's New in This Version.*

```
Graph layout fix
Machines with a lot of VPN tunnels could see the tunnel row's tiles overlap each other in a narrow window. The graph now sizes itself to the widest row, so the tiles keep their spacing and the view scrolls instead of crowding.

Routes: clearer column name
The "Svc order" column is now "Priority" — same value, plainer name. Lower still wins: it's the network service order macOS uses to decide which default route carries traffic.

Terminal dashboard improvements (netlights tui)
The text dashboard gained a Hardware band, so a USB adapter and the network interface it provides finally appear together, along with the hub or port each device hangs off. There's a new Port column in the Devices view; link up and down now use distinct symbols rather than colour alone, so the display stays readable with colour turned off or when piped to a file; and the Interfaces and Routes columns are wider, so similarly-named interfaces no longer truncate to the same text.

Under the hood
Device names that arrive from the hardware itself are now sanitised before they reach a terminal, and the JSON snapshot (netlights --dump-json) gained the network service order.
```

**Note for you, not for Apple:** this is deliberately short. The bulk of 1.9.3 was the
browser UI (`serve`) and the Linux port, and neither ships in the App Store build — `serve`
is compiled out by the sandbox, and the Linux collectors aren't macOS code. Listing either
would describe software this build doesn't contain.

---

## 2 · App Review Notes

*Paste into App Store Connect → App Review Information → Notes. Field limit is 4,000
characters; this block is sized to fit.*

```
NetLights 1.9.3 (build 22). No new capabilities, entitlements, or permission prompts compared with 1.9.2, which you approved on 5 August 2026.

WHAT THE APP DOES
NetLights draws the machine's network interfaces as a layered map — physical ports at the top, virtual tunnels at the bottom — and lights up live link, traffic, device and power state. It is entirely read-only and needs no administrator rights.

ENTITLEMENTS (unchanged from the approved 1.9.2)
com.apple.security.app-sandbox — sandboxed.
com.apple.security.personal-information.location — macOS reveals the current Wi-Fi network name only to an app holding Location access, and NetLights uses it solely to label the Wi-Fi uplink in the graph. No location coordinates are read, stored or transmitted. Declining is fully supported; the uplink is then labelled simply "Wi-Fi".
com.apple.security.device.bluetooth — used solely to list devices that are ALREADY connected, so they can be drawn as attached hardware. The app never scans, pairs or connects. Declining is fully supported; the Bluetooth group then does not appear.
com.apple.security.network.client — a single outbound STUN query (RFC 5389, UDP) that reveals the machine's public IP address. It runs only when the user opens the "Public IP" button in the toolbar or presses Refresh inside that popover — never automatically, never on launch. The app is otherwise entirely passive.

PRIVACY
No data is collected, stored off-device or transmitted. No analytics, no accounts, no third-party SDKs. App Privacy is declared "Data Not Collected". A Privacy toggle in the toolbar masks IP and MAC addresses throughout the interface, for screenshots and screen-sharing.

IN THE PUBLIC SOURCE, BUT NOT IN THIS BUILD
NetLights is open source (MIT) and builds from one codebase for three targets: this sandboxed App Store build, a Developer-ID build, and a Linux build.
1. An HTTP server feature ("serve") that shows the same graph in a web browser is compiled out of this build by the APPSTORE build flag, because the sandbox has no incoming-connections entitlement. This build opens no listening sockets of any kind.
2. Linux-only hardware collectors, including a small D-Bus client that reads the Bluetooth device list on Linux, are each guarded by "#if os(Linux)" and are not compiled into this build. One portable support file compiles on macOS but has no macOS caller and is never invoked; the target enables dead-code stripping. On macOS the Bluetooth list comes from IOBluetooth, gated by the entitlement above, exactly as in 1.9.2.

WHAT CHANGED IN THIS VERSION
A graph layout fix: with many VPN tunnels active the tunnel row's tiles could overlap in a narrow window, and the layout now sizes to the widest row. The Routes tab's "Svc order" column is renamed "Priority". Improvements to the optional terminal dashboard. Device names supplied by attached hardware are sanitised before being printed to a terminal, closing a terminal-escape injection path in the command-line interface. The JSON snapshot gained the network service order (schema version 3, additive).

OPTIONAL COMMAND-LINE INTERFACE
The same binary can also run as a terminal dashboard. It is not required and is not surfaced in the app UI. To try it, run /Applications/NetLights.app/Contents/Resources/netlights tui and press q to quit. It opens no sockets and reads the same data the window shows. The "serve" subcommand in the public documentation is not present in this build.

WHERE TO LOOK
The Graph tab is the main view, with Routes, Interfaces, Devices and DNS alongside it. The renamed "Priority" column is on the Routes tab; the Privacy toggle is in the toolbar next to "Public IP". The layout fix needs several VPN tunnels active in a narrow window to be visible.

Source and release notes: https://github.com/willowhawk-k/NetLights/releases/tag/v1.9.3
```

---

## Checklist before submitting

- [ ] Build **22** selected (must strictly exceed 21, which shipped as 1.9.2)
- [ ] Version string reads **1.9.3**
- [ ] "What's New" pasted from section 1
- [ ] App Review Notes pasted from section 2
- [ ] App Privacy still declared **Data Not Collected** — unchanged
- [ ] No screenshot updates needed; the UI is unchanged apart from one column heading
