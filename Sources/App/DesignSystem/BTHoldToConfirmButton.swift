import SwiftUI

/// Guard for destructive actions: press and hold for `duration` while a red fill sweeps
/// left → right; releasing early cancels. VoiceOver and Reduce Motion users get a plain
/// button that runs `fallback` instead (typically presenting a confirmation dialog), so
/// nobody has to perform a timed gesture they can't see or that relies on motion.
struct BTHoldToConfirmButton: View {
    let title: String
    let duration: Double
    let fallback: () -> Void
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.isEnabled) private var isEnabled

    @State private var progress: Double = 0
    @State private var isHolding = false
    @State private var pressStart: Date?

    init(
        _ title: String,
        duration: Double = 1.2,
        fallback: @escaping () -> Void,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.duration = duration
        self.fallback = fallback
        self.action = action
    }

    var body: some View {
        if reduceMotion || voiceOverEnabled {
            BTButton(fallbackTitle, style: .secondary, action: fallback)
        } else {
            holdButton
        }
    }

    /// "Hold to reset" reads oddly as a click target, so the fallback drops the "Hold to".
    private var fallbackTitle: String {
        guard title.hasPrefix("Hold to ") else { return title }
        let verb = title.dropFirst("Hold to ".count)
        return verb.prefix(1).uppercased() + verb.dropFirst() + "…"
    }

    private var holdButton: some View {
        ZStack {
            label(foreground: .btText)
            label(foreground: .white)
                .background(Color.red)
                .mask(alignment: .leading) {
                    GeometryReader { proxy in
                        Rectangle().frame(width: proxy.size.width * progress)
                    }
                }
        }
        .background(Color.btActiveBackground)
        .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
        .scaleEffect(isHolding ? 0.97 : 1)
        .animation(.btSnappy, value: isHolding)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 24) {
            complete()
        } onPressingChanged: { pressing in
            guard isEnabled else { return }
            isHolding = pressing
            if pressing {
                pressStart = Date()
                withAnimation(.linear(duration: duration)) { progress = 1 }
            } else {
                // `progress` already holds its target value, so time the hold to tell an
                // early release (drain back, cancel) from the one that completes.
                let held = pressStart.map { Date().timeIntervalSince($0) } ?? 0
                pressStart = nil
                if held < duration - 0.05 {
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            }
        }
        .help("Press and hold to confirm")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fallbackTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { fallback() }
    }

    private func label(foreground: Color) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, BTSpacing.md)
            .padding(.vertical, BTSpacing.sm)
    }

    private func complete() {
        guard isEnabled else { return }
        isHolding = false
        pressStart = nil
        action()
        withAnimation(.easeOut(duration: 0.25).delay(0.15)) { progress = 0 }
    }
}
