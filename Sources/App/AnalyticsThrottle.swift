import Foundation

/// Collapses repeated analytics events (e.g. a device failing and recovering in a loop)
/// into one event per key per window, carrying how many were suppressed in between.
/// In the field a single stalled mic produced ~1,650 `deviceSwitchFailed` events an hour.
struct AnalyticsThrottle {
    let window: TimeInterval
    private var lastSent: [String: Date] = [:]
    private var suppressed: [String: Int] = [:]

    init(window: TimeInterval = 10 * 60) {
        self.window = window
    }

    /// Returns nil when the event should be dropped, otherwise the number of
    /// identical events suppressed since the last one that was sent.
    mutating func admit(_ key: String, now: Date = Date()) -> Int? {
        if let last = lastSent[key], now.timeIntervalSince(last) < window {
            suppressed[key, default: 0] += 1
            return nil
        }
        lastSent[key] = now
        return suppressed.removeValue(forKey: key) ?? 0
    }
}
