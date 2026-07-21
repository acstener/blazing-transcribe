import SwiftUI

// MARK: - View Model

@Observable
final class OverlayViewModel {
    var status: OverlayPanel.Status = .idle
    /// Raw audio level from mic (0.0–1.0). Use `smoothedAudioLevel` for animation.
    var audioLevel: Float = 0 {
        didSet { updateSmoothedLevel() }
    }
    /// Exponentially-smoothed level for silky waveform animation.
    var smoothedAudioLevel: Float = 0
    private static let smoothUp: Float = 0.18   // rise gently
    private static let smoothDown: Float = 0.08  // fall even slower
    var isPresented: Bool = false
    var colorScheme: ColorScheme = OverlayViewModel.currentSystemColorScheme()
    var compareBadgeText: String?

    /// Reads the actual macOS dark/light setting directly from user defaults,
    /// bypassing any NSWindow appearance inheritance delay.
    static func currentSystemColorScheme() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }

    /// Incremented each time the panel presents. Used as a SwiftUI .id()
    /// to force material refresh on pre-macOS 26 systems.
    var presentationID: Int = 0

    /// Tracks when silence started during recording to show "no input" hint.
    var silenceStartTime: Date?
    var showNoInputHint: Bool = false
    private let silenceThreshold: Float = 0.01
    private let silenceDelay: TimeInterval = 3.0

    /// Reset smoothed level so the waveform ramps up cleanly on next recording.
    func resetAudioLevel() {
        audioLevel = 0
        smoothedAudioLevel = 0
    }

    private func updateSmoothedLevel() {
        let alpha = audioLevel > smoothedAudioLevel
            ? Self.smoothUp
            : Self.smoothDown
        smoothedAudioLevel += alpha * (audioLevel - smoothedAudioLevel)
    }

    func updateRecordingIndicators() {
        // Track silence duration during recording
        if case .recording = status {
            if audioLevel < silenceThreshold {
                if silenceStartTime == nil {
                    silenceStartTime = Date()
                } else if let start = silenceStartTime, Date().timeIntervalSince(start) >= silenceDelay {
                    showNoInputHint = true
                }
            } else {
                silenceStartTime = nil
                showNoInputHint = false
            }
        } else {
            silenceStartTime = nil
            showNoInputHint = false
        }
    }
}

// MARK: - Content View

struct OverlayContentView: View {
    let viewModel: OverlayViewModel
    let visualStyle: OverlayVisualStyle

    private var waveformMetrics: OverlayWaveformMetrics {
        OverlayWaveformLayout.metrics(for: visualStyle)
    }

    private var primaryTextStyle: AnyShapeStyle {
        if visualStyle == .black {
            return AnyShapeStyle(Color.white.opacity(0.96))
        }
        if #available(macOS 26.0, *) {
            let color: Color = viewModel.colorScheme == .dark
                ? Color.white.opacity(0.95)
                : Color.black.opacity(0.82)
            return AnyShapeStyle(color)
        }
        return AnyShapeStyle(Color.overlayText)
    }

    private var secondaryTextStyle: AnyShapeStyle {
        if visualStyle == .black {
            return AnyShapeStyle(Color.white.opacity(0.68))
        }
        if #available(macOS 26.0, *) {
            let color: Color = viewModel.colorScheme == .dark
                ? Color.white.opacity(0.68)
                : Color.black.opacity(0.52)
            return AnyShapeStyle(color)
        }
        return AnyShapeStyle(Color.overlaySecondaryText)
    }

    private var neutralIconStyle: AnyShapeStyle {
        if visualStyle == .black {
            return AnyShapeStyle(Color.white.opacity(0.74))
        }
        if #available(macOS 26.0, *) {
            return secondaryTextStyle
        }
        return AnyShapeStyle(.secondary)
    }

    var body: some View {
        if #available(macOS 26.0, *), visualStyle == .glass {
            contentForStatus
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    compareBadgeOverlay
                }
                .preferredColorScheme(viewModel.colorScheme)
        } else {
            contentForStatus
                .modifier(OverlayBackgroundModifier(visualStyle: visualStyle))
                // .id() forces SwiftUI to recreate the view each time we
                // present so the material samples the current background.
                .id(viewModel.presentationID)
                .scaleEffect(viewModel.isPresented ? 1.0 : 0.92)
                .opacity(viewModel.isPresented ? 1.0 : 0)
                // Lock color scheme before first render to prevent light-mode flash
                .preferredColorScheme(viewModel.colorScheme)
        }
    }

    @ViewBuilder
    private var contentForStatus: some View {
        switch viewModel.status {
        case .arming, .recording:
            recordingContent
        default:
            standardContent
        }
    }

    // MARK: - Recording (matches React GlassOverlay)

    private var recordingContent: some View {
        OverlayWaveformView(viewModel: viewModel, visualStyle: visualStyle)
            .frame(width: waveformMetrics.totalWidth, height: waveformMetrics.height)
            .padding(.horizontal, waveformMetrics.horizontalPadding)
            .padding(.vertical, waveformMetrics.verticalPadding)
            // TODO: re-enable once styled properly
            // .overlay(alignment: .bottom) {
            //     noMicHint
            //         .opacity(viewModel.showNoInputHint ? 1 : 0)
            //         .padding(.bottom, 1)
            // }
    }

    private var noMicHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "mic.slash")
                .font(.system(size: 9, weight: .semibold))
            Text("No mic input")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(noMicHintColor.opacity(0.5))
    }

    private var noMicHintColor: Color {
        if visualStyle == .black {
            return .white
        }
        if #available(macOS 26.0, *) {
            return viewModel.colorScheme == .dark ? .white : .black
        }
        return Color.overlayText
    }

    // MARK: - Standard states (icon + label)

    private var standardContent: some View {
        HStack(spacing: 6) {
            statusIcon
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16, height: 16)

            statusLabel
                .frame(maxWidth: OverlayLayout.maximumTextWidth, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var compareBadgeOverlay: some View {
        if let badgeText = viewModel.compareBadgeText {
            Text(badgeText)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryTextStyle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(compareBadgeBackground)
                )
                .padding(.top, 3)
                .padding(.trailing, 6)
                .allowsHitTesting(false)
        }
    }

    private var compareBadgeBackground: Color {
        if visualStyle == .black {
            return Color.white.opacity(0.1)
        }
        if #available(macOS 26.0, *) {
            return viewModel.colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.08)
        }
        return Color.black.opacity(0.08)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.status {
        case .idle:
            Image(systemName: "mic.fill")
                .foregroundStyle(neutralIconStyle)
        case .muted:
            Image(systemName: "mic.slash")
                .foregroundStyle(neutralIconStyle)
        case .listening:
            Image(systemName: "waveform")
                .foregroundStyle(.green)
        case .arming:
            Image(systemName: "mic.fill")
                .foregroundStyle(.orange)
        case .recording:
            EmptyView()
        case .transcribing:
            Image(systemName: "brain")
                .foregroundStyle(.blue)
        case .hearing:
            Image(systemName: "waveform.badge.mic")
                .foregroundStyle(.blue)
        case .downloading:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.orange)
        case .loading:
            Image(systemName: "brain")
                .foregroundStyle(.blue)
        case .partial(_, let confirmed):
            Image(systemName: confirmed ? "checkmark.bubble" : "ellipsis.bubble")
                .foregroundStyle(confirmed ? .green : .blue)
        case .result:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch viewModel.status {
        case .idle:
            statusText("Ready")
        case .muted:
            statusText("Muted")
        case .listening:
            statusText("Listening...")
        case .arming:
            statusText("Activating mic...")
        case .recording:
            EmptyView()
        case .transcribing:
            statusText("Transcribing...")
        case .hearing:
            statusText("Hearing you...")
        case .downloading:
            statusText("Downloading model...")
        case .loading:
            statusText("Starting...")
        case .partial(let text, let confirmed):
            if confirmed {
                statusText(text)
            } else {
                partialText(text)
            }
        case .result(let text):
            statusText(text)
        case .warning(let message):
            statusText(message)
        case .error(let message):
            statusText(message)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(primaryTextStyle)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Renders partial text with the last 5 words dimmed.
    private func partialText(_ text: String) -> some View {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let tailCount = 5
        let splitIndex = max(0, words.count - tailCount)

        let confirmed = words.prefix(splitIndex).joined(separator: " ")
        let tail = words.suffix(from: splitIndex).joined(separator: " ")

        return Group {
            if confirmed.isEmpty {
                Text(tail)
                    .foregroundStyle(secondaryTextStyle)
            } else {
                Text(confirmed + " ")
                    .foregroundStyle(primaryTextStyle)
                + Text(tail)
                    .foregroundStyle(secondaryTextStyle)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .lineLimit(2)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Background Modifier

/// Pre-macOS 26: standard HUD material.
/// macOS 26 glass is hosted by AppKit via `NSGlassEffectView`.
private struct OverlayBackgroundModifier: ViewModifier {
    let visualStyle: OverlayVisualStyle

    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: OverlayLayout.glassCornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        switch visualStyle {
        case .glass:
            content
                .background(
                    pillShape
                        .fill(.regularMaterial)
                )
                .overlay(
                    pillShape
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        case .black:
            content
                .background(
                    pillShape
                        .fill(Color.black.opacity(0.82))
                )
                .overlay(
                    pillShape
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        }
    }
}
