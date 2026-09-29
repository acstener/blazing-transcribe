import Foundation
import IOKit

/// Tracks whether a MacBook's lid is closed (clamshell mode).
///
/// With the lid closed, Mac laptops disconnect the built-in mic in hardware, but
/// CoreAudio still lists it — so routing to it records silence. Anything that picks
/// the built-in mic must check this first.
public final class LidStateMonitor {
    public static let shared = LidStateMonitor()
    /// Posted on the main queue when the lid opens or closes. `object` is the monitor.
    public static let didChangeNotification = Notification.Name("LidStateMonitorDidChange")

    public private(set) var isLidClosed: Bool

    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    /// `iokit_family_msg(sub_iokit_powermanagement, 0x100)` from IOPM.h.
    private static let clamshellStateChangeMessage: UInt32 = 0xE003_4100
    private static let clamshellStateBit = 1 << 0

    private init() {
        isLidClosed = Self.readLidClosed()
    }

    /// Reads `AppleClamshellState` from the power-management root domain.
    /// Desktops (and laptops without a lid sensor) report false.
    public static func readLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    /// Starts listening for lid changes. Idempotent.
    public func start() {
        guard notifyPort == nil else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        defer { IOObjectRelease(root) }
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, messageType, argument in
            guard let refcon, messageType == LidStateMonitor.clamshellStateChangeMessage else { return }
            let monitor = Unmanaged<LidStateMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let closed = (Int(bitPattern: argument) & LidStateMonitor.clamshellStateBit) != 0
            monitor.update(closed: closed)
        }, refcon, &notifier)
        guard status == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return
        }
        notifyPort = port
        isLidClosed = Self.readLidClosed()
    }

    private func update(closed: Bool) {
        guard closed != isLidClosed else { return }
        isLidClosed = closed
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
