import AppKit
import Darwin
import FluidAudio
import Foundation

/// In-app diagnostics for tracking model latency, thermal/power state, and
/// memory usage. Logs a baseline line every 60s, an aggressive `[SLOW]` line
/// when a warmup or PTT inference comes in much worse than expected, and
/// exposes a clipboard snapshot for triage.
///
/// Singleton so the menu-bar "Copy Diagnostics" action and the transcription
/// callbacks can hit the same instance without needing AppDelegate plumbing.
public final class DiagnosticsService {
    public static let shared = DiagnosticsService()

    private let lock = NSLock()
    private var baselineTimer: Timer?

    private struct WarmupSample {
        let timestamp: Date
        let durationMs: Double
    }

    private struct PTTSample {
        let timestamp: Date
        let audioSeconds: Double
        let inferenceMs: Double
        var rtf: Double { audioSeconds * 1000.0 / max(inferenceMs, 1) }
    }

    private struct SlowEvent {
        let timestamp: Date
        let summary: String
    }

    private var warmupSamples: [WarmupSample] = []
    private var pttSamples: [PTTSample] = []
    private var slowEvents: [SlowEvent] = []
    private var seenFirstWarmup = false

    private static let warmupSlowThresholdMs: Double = 500
    private static let pttSlowRTFThreshold: Double = 5.0  // RTF below this is suspicious
    private static let pttSlowMinAudioSeconds: Double = 1.0  // ignore very short clips
    private static let maxSamples = 30
    private static let maxSlowEvents = 20

    // MARK: - Sustained slowness (user-facing)

    /// Fired on the recording thread when transcription has been slow for
    /// several consecutive utterances — a sustained condition, not a blip.
    /// Debounced internally to once per 10 minutes.
    public var onSustainedSlowness: ((String) -> Void)?
    /// Fired once when performance recovers after a sustained-slowness report.
    public var onSlownessRecovered: (() -> Void)?

    private static let sustainedSlowWindow = 3   // look at the last N qualifying utterances
    private static let sustainedSlowMinCount = 2 // slow if ≥ this many of them are slow
    private static let sustainedSlowDebounce: TimeInterval = 600
    private var lastSustainedSlownessAt: Date = .distantPast
    private var hasReportedSlowness = false
    private var recentQualifyingSlowFlags: [Bool] = []

    private init() {}

    // MARK: - Lifecycle

    public func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.logBaseline()
        }
        timer.tolerance = 10
        baselineTimer = timer
        logBaseline()
    }

    public func stop() {
        baselineTimer?.invalidate()
        baselineTimer = nil
    }

    // MARK: - Recording

    public func recordWarmup(durationMs: Double) {
        let sample = WarmupSample(timestamp: Date(), durationMs: durationMs)
        var isSlow = false
        var firstEver = false
        lock.lock()
        if !seenFirstWarmup {
            firstEver = true
            seenFirstWarmup = true
        }
        warmupSamples.append(sample)
        if warmupSamples.count > Self.maxSamples {
            warmupSamples.removeFirst(warmupSamples.count - Self.maxSamples)
        }
        // First warmup is always cold; don't flag it.
        if !firstEver, durationMs > Self.warmupSlowThresholdMs {
            isSlow = true
        }
        lock.unlock()

        if isSlow {
            let line = "warmup took \(Int(durationMs))ms (threshold \(Int(Self.warmupSlowThresholdMs))ms) — likely ANE eviction or contention. \(currentEnvSummary())"
            print("[Diag][SLOW] \(line)")
            appendSlowEvent("SLOW_WARMUP duration=\(Int(durationMs))ms \(currentEnvSummary())")
        }
    }

    public func recordPTT(audioSeconds: Double, inferenceMs: Double) {
        let sample = PTTSample(timestamp: Date(), audioSeconds: audioSeconds, inferenceMs: inferenceMs)
        var isSlow = false
        lock.lock()
        pttSamples.append(sample)
        if pttSamples.count > Self.maxSamples {
            pttSamples.removeFirst(pttSamples.count - Self.maxSamples)
        }
        if audioSeconds >= Self.pttSlowMinAudioSeconds, sample.rtf < Self.pttSlowRTFThreshold {
            isSlow = true
        }
        lock.unlock()

        if isSlow {
            let line = String(
                format: "PTT %.1fs audio → %.0fms (rtf=%.1fx, expected ≥%.0fx). %@",
                audioSeconds,
                inferenceMs,
                sample.rtf,
                Self.pttSlowRTFThreshold,
                currentEnvSummary()
            )
            print("[Diag][SLOW] \(line)")
            appendSlowEvent(
                String(
                    format: "SLOW_PTT audio=%.1fs inference=%.0fms rtf=%.1fx %@",
                    audioSeconds,
                    inferenceMs,
                    sample.rtf,
                    currentEnvSummary()
                )
            )
        }

        if audioSeconds >= Self.pttSlowMinAudioSeconds {
            trackSustainedSlowness(sampleIsSlow: isSlow)
        }
    }

    private func trackSustainedSlowness(sampleIsSlow: Bool) {
        var fireSlowness = false
        var fireRecovery = false

        lock.lock()
        recentQualifyingSlowFlags.append(sampleIsSlow)
        if recentQualifyingSlowFlags.count > Self.sustainedSlowWindow {
            recentQualifyingSlowFlags.removeFirst(recentQualifyingSlowFlags.count - Self.sustainedSlowWindow)
        }
        let slowCount = recentQualifyingSlowFlags.filter { $0 }.count
        let windowFull = recentQualifyingSlowFlags.count == Self.sustainedSlowWindow

        if windowFull, slowCount >= Self.sustainedSlowMinCount {
            let now = Date()
            if now.timeIntervalSince(lastSustainedSlownessAt) > Self.sustainedSlowDebounce {
                lastSustainedSlownessAt = now
                hasReportedSlowness = true
                fireSlowness = true
            }
        } else if windowFull, slowCount == 0, hasReportedSlowness {
            hasReportedSlowness = false
            fireRecovery = true
        }
        lock.unlock()

        if fireSlowness {
            onSustainedSlowness?(slownessAdvice())
        }
        if fireRecovery {
            onSlownessRecovered?()
        }
    }

    /// Human-readable likely causes for slow transcription, most actionable first.
    /// Low disk is called out specifically — under ~5 GB free, CoreML silently
    /// falls back from the Neural Engine to GPU/CPU and inference gets several
    /// times slower.
    public func slownessAdvice() -> String {
        var causes: [String] = []

        if let freeGB = Self.freeDiskGB(), freeGB < 5 {
            causes.append(String(
                format: "Your disk has only %.1f GB free. Low disk space disables the fast Neural Engine path — freeing up space usually fixes this.",
                freeGB
            ))
        }

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            causes.append("Your Mac is running hot, which throttles performance.")
        }

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            causes.append("Low Power Mode is on, which slows inference.")
        }

        causes.append("Check Activity Monitor for apps using high memory or CPU — memory pressure is the most common cause of slow transcription.")

        return causes.joined(separator: "\n\n")
    }

    static func freeDiskGB() -> Double? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return Double(capacity) / 1_000_000_000.0
    }

    private func appendSlowEvent(_ summary: String) {
        lock.lock()
        slowEvents.append(SlowEvent(timestamp: Date(), summary: summary))
        if slowEvents.count > Self.maxSlowEvents {
            slowEvents.removeFirst(slowEvents.count - Self.maxSlowEvents)
        }
        lock.unlock()
    }

    // MARK: - Baseline log

    private func logBaseline() {
        lock.lock()
        let warmDurations = warmupSamples.map(\.durationMs)
        let pttRTFs = pttSamples.map(\.rtf)
        let pttCount = pttSamples.count
        let slowCount = slowEvents.count
        lock.unlock()

        let warmP50 = percentile(warmDurations, 0.5)
        let warmP95 = percentile(warmDurations, 0.95)
        let pttRTFP50 = percentile(pttRTFs, 0.5)
        let pttRTFP05 = percentile(pttRTFs, 0.05)  // worst RTF in the bottom 5%

        let warmStr = warmDurations.isEmpty
            ? "n/a"
            : String(format: "p50=%.0fms p95=%.0fms n=%d", warmP50, warmP95, warmDurations.count)
        let pttStr = pttRTFs.isEmpty
            ? "n/a"
            : String(format: "rtf_p50=%.1fx rtf_worst=%.1fx n=%d", pttRTFP50, pttRTFP05, pttCount)

        print("[Diag] \(currentEnvSummary()) warmup{\(warmStr)} ptt{\(pttStr)} slow_events=\(slowCount)")
    }

    // MARK: - Snapshot for clipboard

    public func snapshotForClipboard() -> String {
        lock.lock()
        let warm = warmupSamples
        let ptt = pttSamples
        let slow = slowEvents
        lock.unlock()

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let chip = SystemInfo.chipDescription
        let memMB = Self.currentResidentMemoryMB().map { String(format: "%.0f MB", $0) } ?? "unknown"
        let thermal = Self.thermalStateString(ProcessInfo.processInfo.thermalState)
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"

        var out = ""
        out += "=== Blazing Fast Transcription Diagnostics ===\n"
        out += "Captured: \(dateFormatter.string(from: Date()))\n"
        out += "App: \(version) (build \(build))\n"
        out += "Chip: \(chip)\n"
        out += "OS: \(osVersion)\n"
        out += "Memory (resident): \(memMB)\n"
        out += "Thermal state: \(thermal)\n"
        out += "Low Power Mode: \(lpm)\n"
        out += "Free disk: \(Self.freeDiskGB().map { String(format: "%.1f GB", $0) } ?? "unknown")\n"
        out += "\n"

        out += "--- Keep-warm ticks (last \(warm.count)) ---\n"
        if warm.isEmpty {
            out += "(no samples yet)\n"
        } else {
            out += warm.map { String(format: "%.0f", $0.durationMs) }.joined(separator: " ") + " ms\n"
            let durations = warm.map(\.durationMs)
            out += String(format: "Median: %.0f ms  P95: %.0f ms\n", percentile(durations, 0.5), percentile(durations, 0.95))
        }
        out += "\n"

        out += "--- PTT inferences (last \(ptt.count)) ---\n"
        if ptt.isEmpty {
            out += "(no samples yet)\n"
        } else {
            for sample in ptt.suffix(20) {
                out += String(
                    format: "%4.1fs audio → %5.0f ms (%.1fx RTF)\n",
                    sample.audioSeconds,
                    sample.inferenceMs,
                    sample.rtf
                )
            }
            let rtfs = ptt.map(\.rtf)
            out += String(format: "Median RTF: %.1fx  Worst RTF: %.1fx\n", percentile(rtfs, 0.5), percentile(rtfs, 0.05))
        }
        out += "\n"

        out += "--- Slow events (last \(slow.count)) ---\n"
        if slow.isEmpty {
            out += "(none — nothing unusual)\n"
        } else {
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for event in slow.suffix(20) {
                out += "\(displayFormatter.string(from: event.timestamp))  \(event.summary)\n"
            }
        }
        out += "\nPaste this to dev for triage.\n"
        return out
    }

    public func copyToClipboard() {
        let snapshot = snapshotForClipboard()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot, forType: .string)
        print("[Diag] Snapshot copied to clipboard (\(snapshot.count) chars)")
    }

    // MARK: - Helpers

    private func currentEnvSummary() -> String {
        let thermal = Self.thermalStateString(ProcessInfo.processInfo.thermalState)
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        let memStr = Self.currentResidentMemoryMB().map { String(format: "rss=%.0fMB", $0) } ?? "rss=?"
        let diskStr = Self.freeDiskGB().map { String(format: "disk_free=%.0fGB", $0) } ?? "disk_free=?"
        return "thermal=\(thermal) lpm=\(lpm) \(memStr) \(diskStr)"
    }

    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func currentResidentMemoryMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { boundPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), boundPtr, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }

    /// Linear-interpolation percentile. `p` is in [0,1]. Returns 0 for empty input.
    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
