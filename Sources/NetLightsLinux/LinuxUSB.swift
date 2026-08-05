#if os(Linux)
import Foundation
import NetLightsCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// L3 USB collector: walk /sys/bus/usb/devices and hand the raw attribute strings to the pure
// builder in Core (USBParsing.swift), which returns finished AttachedDevice / HardwarePort
// values. This file is I/O only — no parsing, no model construction.
//
// Plain file reads plus realpath(3): no libudev, no libusb, no subprocess, so the fully
// static musl binary stays dependency-free. Everything here is world-readable and needs no
// privileges. /sys/kernel/debug/usb/devices would be easier to parse in one pass but is
// root-only, so it is deliberately not used.

private let usbRoot = "/sys/bus/usb/devices"

private let deviceAttrs = ["idVendor", "idProduct", "manufacturer", "product", "serial",
                           "bDeviceClass", "bDeviceSubClass", "bDeviceProtocol", "bcdDevice",
                           "version", "speed", "maxchild", "busnum", "devnum", "removable",
                           "authorized"]
private let interfaceAttrs = ["bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol"]

/// Read an attribute file UNTRIMMED — unlike LinuxInterfaces' sysRead. Core owns the
/// trimming, and the leading space the kernel puts in `version` ("%2x.%02x") has to survive
/// the trip so the parser under test sees exactly what the kernel wrote.
private func rawAttr(_ dir: String, _ name: String) -> String? {
    try? String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8)
}

private func resolvedPath(_ path: String) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    guard realpath(path, &buf) != nil else { return nil }
    return String(cString: buf)
}

private func directoryNames(_ path: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

/// Every /sys/bus/usb/devices entry with the attributes its kind needs. A missing directory
/// (no USB support at all) yields an empty array rather than an error.
func linuxUSBNodes() -> [USBSysfsNode] {
    var out: [USBSysfsNode] = []
    for name in directoryNames(usbRoot) {
        let keys: [String]
        switch classifyUSBSysfsName(name) {
        case .interface:        keys = interfaceAttrs
        case .device, .rootHub: keys = deviceAttrs
        case .unknown:          continue   // usbmon1, usb1-port3, a future kernel's additions
        }
        var attrs: [String: String] = [:]
        for k in keys {
            if let v = rawAttr("\(usbRoot)/\(name)", k) { attrs[k] = v }
        }
        out.append(USBSysfsNode(name: name, attributes: attrs))
    }
    return out
}

/// USB device name → the network interface it provides. /sys/class/net/<if>/device is a
/// symlink into the device tree, which is the only reliable signal — USB netdev names vary
/// wildly (enx<mac>, enp0s20f0u2, eth1, usb0) and must never be pattern-matched.
func linuxUSBNetInterfaces() -> [String: String] {
    var out: [String: String] = [:]
    for iface in directoryNames("/sys/class/net") {
        guard let p = resolvedPath("/sys/class/net/\(iface)/device"),
              let dev = usbDeviceName(fromSysfsPath: p) else { continue }
        // One USB device can own several netdevs (a phone in RNDIS+ADB mode); the first by
        // sorted name wins, the same single-interface compromise macOS makes.
        if out[dev] == nil { out[dev] = iface }
    }
    return out
}

/// USB device name → whole-disk capacity. /sys/block lists whole disks only; /sys/class/block
/// would also list partitions and double-count.
func linuxUSBCapacities() -> [String: UInt64] {
    var out: [String: UInt64] = [:]
    for dev in directoryNames("/sys/block") {
        guard let p = resolvedPath("/sys/block/\(dev)"),
              let usb = usbDeviceName(fromSysfsPath: p),
              let bytes = blockCapacityBytes(rawAttr("/sys/block/\(dev)", "size")) else { continue }
        // A multi-slot card reader exposes one block device per LUN; the largest wins, and an
        // empty slot's "0" is already dropped by blockCapacityBytes.
        out[usb] = max(out[usb] ?? 0, bytes)
    }
    return out
}

/// The full USB topology. Degrades at every step: no /sys/bus/usb → empty; no
/// /proc/bus/input/devices → the sysfs boot-protocol HID fallback still classifies boot
/// keyboards and mice.
func linuxUSBTopology() -> USBTopology {
    let hid = (try? String(contentsOfFile: "/proc/bus/input/devices", encoding: .utf8))
        .map(parseProcBusInputDevices) ?? [:]
    return buildUSBTopology(nodes: linuxUSBNodes(),
                            netInterfaces: linuxUSBNetInterfaces(),
                            capacities: linuxUSBCapacities(),
                            hidUsages: hid)
}
#endif
