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
    /// Target pill size. The panel is a fixed stage; SwiftUI (or the glass
    /// width constraint) animates the visible pill to this size.
    var pillLayout = OverlayPillLayout(
        width: OverlayPillMetrics.quantize(OverlayLayout.glassSize.width),
        height: OverlayPillMetrics.singleLineHeight
    )
    /// Bumped each time the pill enters `.arming` so the mic glyph pulses once.
    var armingPulseCount: Int = 0

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

/// One continuously morphing pill. The panel hosting this view is a fixed,
/// invisible stage; the pill is drawn bottom-centred inside it and only its
/// drawn size animates, so nothing in AppKit moves or resizes per status.
struct OverlayContentView: View {
    let viewModel: OverlayViewModel
    let visualStyle: OverlayVisualStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usesNativeGlass: Bool {
        if #available(macOS 26.0, *), visualStyle == .glass {
            return true
        }
        return false
    }

    private var presentation: OverlayPillPresentation {
        OverlayPillPresentation(status: viewModel.status)
    }

    private var waveformMetrics: OverlayWaveformMetrics {
        OverlayWaveformLayout.metrics(for: visualStyle)
    }

    /// Pill width/height morph. Reduce Motion: short ease-out, no spring.
    private var sizeAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32)
    }

    /// Crossfade between states' content.
    private var contentAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.2)
    }

    /// Size of the content area. On the native glass path AppKit owns the
    /// pill chrome (and its insets); SwiftUI only draws content.
    private var contentSize: CGSize {
        let insets = OverlayPillMetrics.chromeInsets(nativeGlass: usesNativeGlass)
        return CGSize(
            width: max(0, viewModel.pillLayout.width - insets.left - insets.right),
            height: max(0, viewModel.pillLayout.height - insets.top - insets.bottom)
        )
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

    private func symbolStyle(for tone: OverlayPillTone) -> AnyShapeStyle {
        switch tone {
        case .neutral:
            return neutralIconStyle
        case .ember:
            return AnyShapeStyle(Color.overlayEmber)
        case .success:
            return AnyShapeStyle(Color.green)
        case .warning:
            return AnyShapeStyle(Color.overlayWarning)
        case .error:
            return AnyShapeStyle(Color.red)
        }
    }

    var body: some View {
        if usesNativeGlass {
            // AppKit sizes the NSGlassEffectView (animated width constraint);
            // the content sits centred at its target size and is clipped by
            // the glass content container while the glass morphs.
            pillContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    compareBadgeOverlay
                }
                .preferredColorScheme(viewModel.colorScheme)
        } else {
            pill
                // .id() forces SwiftUI to recreate the view each time we
                // present so the material samples the current background
                // (and the pill appears at its size without morphing in).
                .id(viewModel.presentationID)
                .scaleEffect(viewModel.isPresented ? 1.0 : 0.92, anchor: .bottom)
                .opacity(viewModel.isPresented ? 1.0 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, OverlayPillMetrics.stagePadding)
                // Lock color scheme before first render to prevent light-mode flash
                .preferredColorScheme(viewModel.colorScheme)
        }
    }

    /// SwiftUI-drawn pill (pre-26 material and black styles).
    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: OverlayLayout.glassCornerRadius, style: .continuous)
        let size = viewModel.pillLayout
        return pillContent
            // Only the pill's frame and chrome animate with the size spring;
            // content keeps its own crossfade and never reflows mid-morph.
            .animation(sizeAnimation) { content in
                content
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .modifier(OverlayBackgroundModifier(visualStyle: visualStyle, shape: shape))
            }
            .geometryGroup()
    }

    /// Content for the current status, laid out at the target size.
    private var pillContent: some View {
        let presentation = presentation
        let size = contentSize
        return ZStack {
            if presentation.kind == .waveform {
                OverlayWaveformView(viewModel: viewModel, visualStyle: visualStyle)
                    .frame(width: waveformMetrics.totalWidth, height: waveformMetrics.height)
                    .transition(.opacity)
            } else {
                glyphAndLabel(presentation)
                    .transition(.opacity)
            }
        }
        .animation(contentAnimation, value: presentation.contentAnimationKey)
        .frame(width: size.width, height: size.height)
    }

    private func glyphAndLabel(_ presentation: OverlayPillPresentation) -> some View {
        HStack(spacing: OverlayPillMetrics.symbolSpacing) {
            if let symbolName = presentation.symbolName {
                symbol(symbolName, presentation: presentation)
                    .transition(.opacity)
            }
            if let label = presentation.label {
                labelText(label, presentation: presentation)
                    .font(.system(size: OverlayPillMetrics.labelFontSize, weight: .medium))
                    .lineLimit(presentation.maxLines)
                    // Streaming text keeps the newest words visible.
                    .truncationMode(presentation.isStreaming ? .head : .tail)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.opacity)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, OverlayPillMetrics.contentPadding(nativeGlass: usesNativeGlass))
    }

    private func symbol(_ name: String, presentation: OverlayPillPresentation) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(symbolStyle(for: presentation.tone))
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            // Transcribing: variable colour sweep. Never loops under Reduce Motion.
            .symbolEffect(.variableColor.iterative, isActive: presentation.isBusy && !reduceMotion)
            // Arming: a single pulse (skipped under Reduce Motion).
            .symbolEffect(.pulse, options: .nonRepeating, value: reduceMotion ? 0 : viewModel.armingPulseCount)
            .frame(width: OverlayPillMetrics.symbolSize, height: OverlayPillMetrics.symbolSize)
    }

    /// One `Text` for every label so changes crossfade in place. Unconfirmed
    /// partials dim their last five words.
    private func labelText(_ text: String, presentation: OverlayPillPresentation) -> Text {
        guard presentation.dimsTail else {
            return Text(text).foregroundStyle(primaryTextStyle)
        }

        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let tailCount = 5
        let splitIndex = max(0, words.count - tailCount)
        let confirmed = words.prefix(splitIndex).joined(separator: " ")
        let tail = words.suffix(from: splitIndex).joined(separator: " ")

        if confirmed.isEmpty {
            return Text(tail).foregroundStyle(secondaryTextStyle)
        }
        return Text(confirmed + " ").foregroundStyle(primaryTextStyle)
            + Text(tail).foregroundStyle(secondaryTextStyle)
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
}

// MARK: - Background Modifier

/// Pre-macOS 26: standard HUD material, or the solid black pill.
/// macOS 26 glass is hosted by AppKit via `NSGlassEffectView`.
private struct OverlayBackgroundModifier: ViewModifier {
    let visualStyle: OverlayVisualStyle
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        switch visualStyle {
        case .glass:
            content
                .background(shape.fill(.regularMaterial))
                .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        case .black:
            content
                .background(shape.fill(Color.black.opacity(0.82)))
                .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 14, y: 8)
        }
    }
}
