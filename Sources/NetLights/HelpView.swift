import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("What you're looking at", icon: "square.stack.3d.up.fill") {
                    para("NetLights arranges every network interface on your Mac into horizontal bands that mirror the network stack — from the physical chassis ports at the top down to virtual tunnels at the bottom. Lines show how interfaces relate; small LEDs show live link and traffic state.")
                }

                section("The layer bands", icon: "rectangle.3.group.fill") {
                    bullet("Internet + gateways (top)", "A top row holds the Internet node and a tier of gateway chips pinned above the host each one lives on.")
                    bullet("Hardware (L0)", "The physical USB-C / Thunderbolt receptacles on your Mac's chassis, the Wi-Fi network entity, a Displays entity, a Bluetooth entity, the battery, plus directly-attached devices (iPhone, MiFi, dongles). Position labels (Left · Front, Right, …) come from a per-model layout table.")
                    bullet("Physical (L1)", "Real link-layer interfaces: Wi-Fi, Thunderbolt-bridge members (en1–en3), USB Ethernet, and app/VM virtual adapters. TB and iPhone interfaces sit directly under the hardware port they belong to.")
                    bullet("Data Link (L2)", "Bridges and VLANs — e.g. bridge0, the Thunderbolt Bridge — drawn centered over their member ports.")
                    bullet("Virtual (L3+)", "Everything software-defined: VPN/utun tunnels, loopback, AWDL (AirDrop), Continuity, and system interfaces.")
                }

                section("Nodes, LEDs & lines", icon: "lightbulb.fill") {
                    bullet("Green dot", "The interface (or port) has an active link / a device is attached.")
                    bullet("Amber ant-crawl", "Live traffic. The dashes march while bytes are moving and hold steady (no blink) for ~3 s after activity stops.")
                    bullet("Dim dot", "No link / nothing attached.")
                    bullet("Connection lines", "Show relationships: hardware port → its en* interfaces, bridge ↔ members, and interface → gateway. Emphasized links (iPhone↔port, VPN egress) stay brightly lit.")
                    bullet("Throughput on the wire", "A wire carrying a single interface's flow shows its live rate (↓ down / ↑ up, in bits per second — Kbps/Mbps/Gbps, like the link speed). Hover any wire for a Link tooltip: negotiated link speed, live Down/Up, and Received/Sent byte totals (counted since the interface came up). Per-app breakdown isn't available to a sandboxed app.")
                }

                section("Hardware ports & power", icon: "powerplug.fill") {
                    bullet("Lit port", "Anything physically attached — a Thunderbolt device, a USB-C cable/device, an iPhone, or even a charger — lights the port, regardless of whether it carries network traffic.")
                    bullet("Plug badge", "A yellow plug (powerplug) badge marks a port with a USB-C charger attached — an active connection that presents no USB data device.")
                    bullet("iPhone / iPad link", "A USB-connected iPhone or iPad is detected via the IOKit USB tree (distinguished by name), mapped to its physical receptacle, and joined to that port with a green “USB-C” link.")
                    bullet("Battery & charging", "A battery entity in the Hardware row shows charge level and whether the Mac is on battery, powered (full, on the adapter), or charging; hover it for the adapter (name + wattage), also echoed in the status bar. This is a SYSTEM fact: macOS exposes no per-port power direction, so charging is never pinned to a USB-C port — and MagSafe can't be told from USB-C (it's electrically USB-C PD), nor can power the Mac provides out to an accessory be shown.")
                }

                section("Recognizing attached devices", icon: "shippingbox.fill") {
                    para("Each USB peripheral is classified and drawn with a fitting icon — hover any chip for its name, class, and port:")
                    HStack(spacing: 16) {
                        DeviceNodeView(device: AttachedDevice(id: "a", name: "AirPods Max", receptacle: 0, kind: .audio))
                        DeviceNodeView(device: AttachedDevice(id: "b", name: "MagSafe Battery", receptacle: 0, kind: .battery))
                        DeviceNodeView(device: AttachedDevice(id: "c", name: "USB PowerPack", receptacle: 0, kind: .generic))
                        HardwarePortNodeView(port: HardwarePort(id: 1, side: "Left", position: "Front",
                            childBSDNames: [], hasConnectedDevice: true, hasPower: true))
                    }
                    .padding(.vertical, 4)
                    bullet("Plug badge", "A charger (power, no data device) adds a yellow plug to its port — see the rightmost example above.")
                    bullet("Network devices", "A MiFi or USB-Ethernet adapter shows as a device with the interface it provides anchored beneath it.")
                    bullet("Hub & dock hierarchy", "Devices behind a USB hub or dock nest beneath it as a tidy tree — each port owns its own column so subtrees never overlap or cross wires.")
                    bullet("Devices tab", "Switch to the Devices tab for a full table — manufacturer, bus (USB 2.1 / 3.2 …), negotiated link speed, USB class, vendor:product id, and which port each device sits on.")
                }

                section("External displays", icon: "display.2") {
                    para("Connected monitors are detected and grouped under a Displays entity in the Hardware row; hover one for its maker, model, and resolution / refresh.")
                    bullet("Why they're grouped", "macOS exposes no way for an unprivileged app to learn which physical port a monitor uses — a DisplayPort-over-USB-C display never appears in the Thunderbolt tree, and the display data carries no connection type. So displays are listed rather than pinned to a guessed port.")
                }

                section("Bluetooth devices", icon: "wave.3.right") {
                    para("Connected Bluetooth devices are grouped under a Bluetooth entity in the Hardware row — each with its type and, for input devices (mice, keyboards, trackpads), its battery %.")
                    bullet("Permission", "macOS gates the connected-device list behind Bluetooth access, so NetLights asks for it — solely to list already-connected devices (it never scans, pairs, or connects). Decline and the Bluetooth entity just doesn't appear. Changed your mind? Use Help ▸ Check Bluetooth Permission to reopen the system pane.")
                    bullet("Audio battery", "AirPods / headphone / speaker battery isn't shown: macOS keeps it in the Bluetooth daemon (no in-process API). Input-device battery comes from the IORegistry, which is readable in-process.")
                }

                section("Gateways & the Internet", icon: "globe") {
                    bullet("Internet node", "Sits in the top row; every default gateway links up to it. The chip's column traces back down to the device/interface that egress goes through.")
                    bullet("GW #1, #2, … (orange)", "Default-route gateways, pinned in a tier above the host they live on (iPhone, Wi-Fi router, dongle). The number is precedence — GW #1 is the one that wins the 0.0.0.0/0 race (the active uplink).")
                    bullet("VPN GW (blue)", "A default route over a tunnel — pinned next to its utun down in the Virtual row, with an egress link to the physical gateway it ultimately exits through.")
                }

                section("Where the data comes from", icon: "cpu.fill") {
                    bullet("Interfaces & stats", "getifaddrs() for addresses; sysctl(NET_RT_IFLIST2) for link state, MAC, MTU and the 64-bit rx/tx byte counters that drive the on-wire throughput.")
                    bullet("Routes & gateways", "sysctl(NET_RT_DUMP) over the PF_ROUTE socket.")
                    bullet("Friendly names", "SystemConfiguration (SCNetworkInterface) for hardware-port display names.")
                    bullet("Port topology", "Read in-process via IOKit — IOThunderboltSwitch for receptacle status, IOUSBHostDevice for the USB device tree + iPhone port, and AppleHPM (USB-C PD controller) for attachment/charger state. No subprocesses.")
                    bullet("Device types", "IOKit registry properties (vendor, idVendor/idProduct, bcdUSB, link speed) plus each device's interface classes and HID usage classify composite devices (mice, keyboards, game controllers, audio, webcams); CoreGraphics for external displays.")
                    bullet("Bluetooth", "IOBluetooth for the connected-device list (with permission); the IORegistry for input-device battery.")
                    bullet("System power", "AppleSmartBattery for AC/charging state and adapter wattage (system-level only).")
                    bullet("Wi-Fi link speed", "CoreWLAN's negotiated transmit rate (the legacy baud field under-reports modern Wi-Fi).")
                }

                section("Capabilities & restrictions", icon: "exclamationmark.triangle.fill") {
                    bullet("No admin rights", "Everything is read-only and runs as your user — NetLights never changes configuration.")
                    bullet("Refresh cadence", "Interface/route data refreshes every 0.75 s; the slower port-topology probe runs ~every 5 s on a background thread so the UI never stalls.")
                    bullet("Link speed", "Wired links read the interface's negotiated baud rate (64-bit via NET_RT_IFLIST2); Wi-Fi uses CoreWLAN's current transmit rate, which fluctuates as the radio adapts.")
                    bullet("Display ports", "External monitors are detected but not mapped to a specific port — macOS doesn't expose which receptacle (or HDMI) a display uses to an unprivileged app, and there's no permission that unlocks it.")
                    bullet("USB-C power direction", "macOS exposes no per-port power direction. A receiving port (a dock charging the Mac) and a providing port (the Mac powering an accessory) are byte-for-byte identical in the registry — only system-wide charging is knowable (AppleSmartBattery). So charging is shown in the status bar, never pinned to a port.")
                    bullet("Port front/rear labels", "Receptacle position labels come from a hand-curated per-model table and may be approximate on some Macs — connection/power state itself is read live and accurate.")
                    bullet("iPhone visibility", "A locked iPhone is hidden from some USB listings; NetLights reads the IOKit registry directly to find it.")
                    bullet("Wi-Fi network name", "macOS only reveals the current SSID to apps with Location access, so NetLights requests it — used solely to label the Wi-Fi uplink. No location coordinates are ever read, stored, or shared, and you can decline (the uplink just shows \"Wi-Fi\"). Changed your mind? Use Help ▸ Check Location Permission (Wi-Fi names) to reopen the system pane.")
                    bullet("Bluetooth devices", "macOS gates the connected-device list behind Bluetooth access; NetLights requests it solely to list already-connected devices (never scanning/pairing). Decline and the Bluetooth entity is hidden. Audio-device battery (AirPods/headphones) isn't available to an in-process app.")
                }

                Divider()

                section("Credits", icon: "heart.fill") {
                    para("NetLights was created by \(AppInfo.author), pair-programmed with Claude (Anthropic). Claude helped architect the layered layout engine, the low-level sysctl/IOKit data plumbing, and this help system.")
                    para(AppInfo.copyright)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("NetLights is 100% free and open source under the MIT License.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Source, issues & releases on GitHub →", destination: URL(string: AppInfo.repoURL)!)
                        .font(.callout)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Building blocks

    private var header: some View {
        HStack(spacing: 14) {
            AppIconView().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(AppInfo.name) Help")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(AppInfo.tagline)
                    .font(.callout).foregroundColor(.secondary)
            }
        }
    }

    private func section<Content: View>(_ title: String, icon: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundColor(.primary)
            content()
        }
    }

    private func para(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ term: String, _ desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundColor(.accentColor)
                .padding(.top, 5)
            (Text(term + " — ").font(.callout.weight(.semibold))
             + Text(desc).font(.callout).foregroundColor(.secondary))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
