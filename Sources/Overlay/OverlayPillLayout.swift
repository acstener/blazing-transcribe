import AppKit
import Foundation

// MARK: - Presentation

/// Semantic colour for the pill's glyph. Resolved to a concrete colour in the view.
enum OverlayPillTone: Equatable {
    case neutral
    case ember
    case success
    case warning
    case error
}

/// Everything the pill draws for a status, reduced to plain values so layout
/// and view stay in agreement and the mapping is testable.
struct OverlayPillPresentation: Equatable {
    enum Kind: Equatable {
        /// Live Ember waveform only (recording).
        case waveform
        /// Glyph only (arming).
        case symbol
        /// Optional glyph plus a text label.
        case label
    }

    var kind: Kind
    var symbolName: String?
    var tone: OverlayPillTone = .neutral
    var label: String?
    var maxLines: Int = 1
    /// Streaming partial text (Turbo): grow-only width, head truncation, no crossfade per update.
    var isStreaming = false
    /// Unconfirmed partial text dims its trailing words.
    var dimsTail = false
    /// Busy states run the variable-colour symbol effect (not under Reduce Motion).
    var isBusy = false
    /// Arming pulses the mic glyph once.
    var pulsesOnce = false

    init(
        kind: Kind,
        symbolName: String? = nil,
        tone: OverlayPillTone = .neutral,
        label: String? = nil,
        maxLines: Int = 1,
        isStreaming: Bool = false,
        dimsTail: Bool = false,
        isBusy: Bool = false,
        pulsesOnce: Bool = false
    ) {
        self.kind = kind
        self.symbolName = symbolName
        self.tone = tone
        self.label = label
        self.maxLines = maxLines
        self.isStreaming = isStreaming
        self.dimsTail = dimsTail
        self.isBusy = isBusy
        self.pulsesOnce = pulsesOnce
    }

    init(status: OverlayPanel.Status) {
        switch status {
        case .idle:
            self.init(kind: .label, symbolName: "mic.fill", label: "Ready")
        case .muted:
            self.init(kind: .label, symbolName: "mic.slash.fill", label: "Muted")
        case .listening:
            self.init(kind: .label, symbolName: "mic.fill", label: "Listening…")
        case .arming:
            self.init(kind: .symbol, symbolName: "mic.fill", tone: .ember, pulsesOnce: true)
        case .recording:
            self.init(kind: .waveform)
        case .transcribing:
            self.init(kind: .label, symbolName: "waveform", label: "Transcribing…", isBusy: true)
        case .hearing:
            self.init(kind: .label, symbolName: "mic.fill", tone: .ember, label: "Hearing you…")
        case .downloading:
            self.init(kind: .label, symbolName: "arrow.down.circle", label: "Downloading model…")
        case .loading:
            self.init(kind: .label, symbolName: "hourglass", label: "Starting…")
        case .partial(let text, let confirmed):
            self.init(kind: .label, label: text, isStreaming: true, dimsTail: !confirmed)
        case .result(let text, let wordCount, let duration):
            self.init(
                kind: .label,
                symbolName: "checkmark",
                tone: .success,
                label: OverlayResultSummary.label(text: text, wordCount: wordCount, duration: duration)
            )
        case .warning(let message):
            self.init(kind: .label, symbolName: "exclamationmark.triangle.fill", tone: .warning, label: message, maxLines: 2)
        case .error(let message):
            self.init(kind: .label, symbolName: "exclamationmark.triangle.fill", tone: .error, label: message, maxLines: 2)
        }
    }

    /// Changes to this key crossfade the pill's content. Streaming text is
    /// excluded so 20 Hz partial updates never flicker.
    var contentAnimationKey: String {
        let text = isStreaming ? "<streaming>" : (label ?? "")
        return "\(kind)|\(symbolName ?? "-")|\(text)"
    }
}

// MARK: - Result label

enum OverlayResultSummary {
    /// "42 words · 0.28s". The duration is dropped when unknown or zero
    /// (realtime engines don't record a transcription duration).
    static func label(text: String, wordCount: Int?, duration: TimeInterval?) -> String {
        let words = wordCount ?? text.split(whereSeparator: \.isWhitespace).count
        var label = words == 1 ? "1 word" : "\(words) words"
        if let duration, duration > 0 {
            label += " · " + formatDuration(duration)
        }
        return label
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 10 {
            return String(format: "%.2fs", locale: Locale(identifier: "en_US_POSIX"), duration)
        }
        return String(format: "%.1fs", locale: Locale(identifier: "en_US_POSIX"), duration)
    }
}

// MARK: - Layout

struct OverlayPillLayout: Equatable {
    var width: CGFloat
    var height: CGFloat
}

enum OverlayPillMetrics {
    static let widthQuantum: CGFloat = 8
    static let singleLineHeight: CGFloat = OverlayLayout.glassSize.height
    static let twoLineHeight: CGFloat = 56
    static let minWidth: CGFloat = 40
    static let maxWidth: CGFloat = 296
    static let symbolOnlyWidth: CGFloat = 56
    static let symbolSize: CGFloat = 16
    static let symbolSpacing: CGFloat = 6
    static let labelFontSize: CGFloat = 12.5
    /// Transparent margin around the pill inside the fixed panel, leaving room for shadows.
    static let stagePadding: CGFloat = 24
    /// Extra room so AppKit and SwiftUI text measurement differences never truncate.
    static let textMeasurementSlack: CGFloat = 2

    /// The overlay panel is a fixed, invisible stage sized for the largest pill.
    static var stageSize: NSSize {
        NSSize(width: maxWidth + 2 * stagePadding, height: twoLineHeight + 2 * stagePadding)
    }

    static func chromeInsets(nativeGlass: Bool) -> NSEdgeInsets {
        nativeGlass ? OverlayLayout.glassContentInsets : NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    /// Horizontal padding inside the content area (on top of any glass insets).
    static func contentPadding(nativeGlass: Bool) -> CGFloat {
        nativeGlass ? 4 : 12
    }

    static func maxTextWidth(hasSymbol: Bool, nativeGlass: Bool) -> CGFloat {
        let insets = chromeInsets(nativeGlass: nativeGlass)
        let symbol = hasSymbol ? symbolSize + symbolSpacing : 0
        return maxWidth - insets.left - insets.right - 2 * contentPadding(nativeGlass: nativeGlass) - symbol
    }

    static func quantize(_ width: CGFloat) -> CGFloat {
        let clamped = min(max(width, minWidth), maxWidth)
        return min(maxWidth, (clamped / widthQuantum).rounded(.up) * widthQuantum)
    }

    static func measureLabel(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    static func layout(
        for presentation: OverlayPillPresentation,
        visualStyle: OverlayVisualStyle,
        nativeGlass: Bool,
        measure: (String) -> CGFloat = OverlayPillMetrics.measureLabel
    ) -> OverlayPillLayout {
        let insets = chromeInsets(nativeGlass: nativeGlass)
        let horizontalChrome = insets.left + insets.right

        switch presentation.kind {
        case .waveform:
            let metrics = OverlayWaveformLayout.metrics(for: visualStyle)
            let raw = metrics.totalWidth + 2 * metrics.horizontalPadding + horizontalChrome
            return OverlayPillLayout(width: quantize(raw), height: singleLineHeight)

        case .symbol:
            return OverlayPillLayout(width: quantize(symbolOnlyWidth), height: singleLineHeight)

        case .label:
            let hasSymbol = presentation.symbolName != nil
            let maxText = maxTextWidth(hasSymbol: hasSymbol, nativeGlass: nativeGlass)
            let measured = measure(presentation.label ?? "") + textMeasurementSlack
            let wraps = measured > maxText && presentation.maxLines >= 2
            let textWidth = min(measured, maxText)
            let symbol = hasSymbol ? symbolSize + symbolSpacing : 0
            let raw = horizontalChrome + 2 * contentPadding(nativeGlass: nativeGlass) + symbol + textWidth
            return OverlayPillLayout(width: quantize(raw), height: wraps ? twoLineHeight : singleLineHeight)
        }
    }
}

// MARK: - Width governor

/// Keeps the pill from "breathing" while Turbo streams partial text:
/// widths are already quantised to 8pt; while streaming, the width only
/// grows and changes at most 8 times a second. Any non-streaming status
/// ends the session and applies its width directly (the one shrink).
struct OverlayPillWidthGovernor {
    static let streamingMinInterval: TimeInterval = 1.0 / 8.0

    struct Decision: Equatable {
        var width: CGFloat
        /// When set, the target was held back; resolve again after this delay.
        var retryAfter: TimeInterval?
    }

    private(set) var streamingWidth: CGFloat?
    private var lastStreamingChangeAt: TimeInterval?

    mutating func reset() {
        streamingWidth = nil
        lastStreamingChangeAt = nil
    }

    mutating func resolve(target: CGFloat, isStreaming: Bool, now: TimeInterval) -> Decision {
        guard isStreaming else {
            reset()
            return Decision(width: target)
        }

        guard let current = streamingWidth, let lastChange = lastStreamingChangeAt else {
            streamingWidth = target
            lastStreamingChangeAt = now
            return Decision(width: target)
        }

        guard target > current else {
            return Decision(width: current)
        }

        let elapsed = now - lastChange
        if elapsed < Self.streamingMinInterval {
            return Decision(width: current, retryAfter: Self.streamingMinInterval - elapsed)
        }

        streamingWidth = target
        lastStreamingChangeAt = now
        return Decision(width: target)
    }
}
