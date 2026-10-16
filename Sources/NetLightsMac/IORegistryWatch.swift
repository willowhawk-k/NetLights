import Foundation
import IOKit

/// Flags I/O Registry topology changes so the full-plane walk (`IOKitProbe.serviceTree()`)
/// runs only when something that feeds the port status was published or terminated — plus
/// a slow fallback and manual Refresh — instead of on every third poll.
///
/// Why this exists (2026-10-15, `.maintainer/2026-10-14-sluggish-after-5-days.md`): the
/// walk serializes every property of ~3,100 registry nodes, and on this Mac that cost
/// 1.6–1.9 s of kernel/IPC time per pass, every 3 s — most of a core, continuously, for
/// data that changes only when hardware is plugged or unplugged. IOKit will tell us when
/// that happens, so ask it.
///
/// The callback only flips a flag under a lock; the consumer (`NetworkMonitor.refresh`)
/// reads and clears it on its own cadence, so a burst of notifications coalesces into one
/// walk, and nothing here touches main-actor state.
final class IORegistryWatch: @unchecked Sendable {
    /// Classes whose publish/terminate can change what the tree parsers produce: USB devices
    /// and hubs (`usbScan`), Thunderbolt/USB4 switches (`thunderbolt`), disks (`storageScan`,
    /// via their `IOMedia`), and HID devices (the usage map that classifies Bluetooth input
    /// devices). `IOServiceMatching` matches subclasses too.
    static let topologyClasses = ["IOUSBHostDevice", "IOThunderboltSwitch", "IOMedia", "IOHIDDevice"]

    private let classes: [String]
    private let lock = NSLock()
    private var dirty = false
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let queue = DispatchQueue(label: "netlights.ioregistry-watch")

    init(classes: [String]) { self.classes = classes }
    deinit { stop() }

    /// Registers for matched + terminated notifications on every class. Idempotent.
    func start() {
        guard port == nil, let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(p, queue)
        port = p
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for cls in classes {
            for kind in [kIOMatchedNotification, kIOTerminatedNotification] {
                var iter: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(p, kind, IOServiceMatching(cls),
                                                       Self.callback, refcon, &iter) == KERN_SUCCESS
                else { continue }
                Self.drain(iter)   // a matching notification arms only once its iterator is exhausted
                iterators.append(iter)
            }
        }
    }

    func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators.removeAll()
        if let p = port {
            IONotificationPortDestroy(p)
            port = nil
        }
    }

    /// True if anything relevant was published or terminated since the previous call.
    /// Clears the flag.
    func consumeDirty() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = dirty
        dirty = false
        return was
    }

    private func markDirty() {
        lock.lock(); defer { lock.unlock() }
        dirty = true
    }

    private static let callback: IOServiceMatchingCallback = { refcon, iterator in
        drain(iterator)
        guard let refcon else { return }
        Unmanaged<IORegistryWatch>.fromOpaque(refcon).takeUnretainedValue().markDirty()
    }

    private static func drain(_ iterator: io_iterator_t) {
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            IOObjectRelease(obj)
            obj = IOIteratorNext(iterator)
        }
    }
}
