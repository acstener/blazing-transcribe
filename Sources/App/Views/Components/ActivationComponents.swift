import SwiftUI
import AppKit
import HotkeyModule

// Small building blocks for onboarding and first-run Home (workstream G2).
// Every motion here has a Reduce Motion fallback.

// MARK: - Progress bar

/// Thin progress bar: indeterminate (a sliding segment) until a fraction is known,
/// then determinate. Under Reduce Motion the indeterminate state is a static tint.
struct ActivationProgressBar: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.btBorder)
                if let fraction {
                    Capsule()
                        .fill(Color.btAccent)
                        .frame(width: max(4, geo.size.width * min(max(fraction, 0), 1)))
                } else if reduceMotion {
                    Capsule().fill(Color.btAccent.opacity(0.3))
                } else {
                    TimelineView(.animation) { timeline in
                        let period = 1.4
                        let t = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        let eased = 0.5 - 0.5 * cos(t * .pi)
                        let segment = geo.size.width * 0.32
                        Capsule()
                            .fill(Color.btAccent)
                            .frame(width: segment)
                            .offset(x: -segment + eased * (geo.size.width + segment))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

// MARK: - Checklist row

/// One self-checking row of the Setup checklist.
struct SetupChecklistRowView: View {
    let row: SetupChecklist.Row
    let systemImage: String
    var action: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: BTSpacing.sm + 4) {
            indicator
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.btText)
                Text(row.caption)
                    .font(.btCaption)
                    .foregroundStyle(captionColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if case .working(let fraction) = row.status {
                    ActivationProgressBar(fraction: fraction)
                        .padding(.top, 4)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, BTSpacing.sm + 2)
        .padding(.vertical, BTSpacing.sm + 2)
        .animation(reduceMotion ? nil : .btSnappy, value: row)
        .accessibilityElement(children: .contain)
    }

    private var captionColor: Color {
        if case .failed = row.status { return .red }
        return Color.btSecondaryText
    }

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            switch row.status {
            case .done:
                Circle().fill(Color.green.opacity(0.14))
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            case .failed:
                Circle().fill(Color.red.opacity(0.1))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.red)
            case .waiting, .working:
                Circle().fill(Color.btActiveBackground)
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.btText)
            case .needsAction:
                Circle().strokeBorder(Color.btBorder, lineWidth: 1.5)
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.btSecondaryText)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.status {
        case .needsAction(let title), .failed(let title):
            if let action {
                Button(action: action) {
                    Text(title)
                        .font(.btLabel)
                        .foregroundStyle(Color.btAccentForeground)
                        .padding(.horizontal, BTSpacing.sm + 4)
                        .padding(.vertical, 5)
                        .background(Color.btAccent)
                        .clipShape(Capsule())
                }
                .buttonStyle(BTButtonStyle())
                .accessibilityLabel("\(title): \(row.title)")
            }
        case .waiting(let linkTitle):
            VStack(alignment: .trailing, spacing: 2) {
                Text("Waiting…")
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
                if let linkTitle, let action {
                    Button(linkTitle, action: action)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.btText)
                        .underline()
                }
            }
        case .working, .done:
            EmptyView()
        }
    }
}

// MARK: - fn conflict warning

/// Inline amber warning when fn is the push-to-talk key and macOS also acts on fn.
/// Offers a one-click switch to ⌃⌥Space and a shortcut to Keyboard Settings. Never auto-switches.
struct FnConflictWarning: View {
    @Environment(AppViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var switchError: String?

    static let alternativeShortcut = GlobalShortcut(
        keyCode: 0x31, // Space
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    /// Reads `pttShortcutLabel` so the view re-evaluates when the shortcut changes
    /// (`ShortcutConfig` itself isn't observable).
    private var isVisible: Bool {
        _ = viewModel.pttShortcutLabel
        return viewModel.isFnShortcutConflicting
    }

    var body: some View {
        Group {
            if isVisible {
                content
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .btSoft, value: isVisible)
        .onAppear { viewModel.refreshFnKeySystemAction() }
    }

    private var title: String {
        switch viewModel.fnKeySystemAction {
        case .systemDefault: return "Your Mac also uses fn"
        default: return "fn is set to \(viewModel.fnKeySystemAction.displayName)"
        }
    }

    private var detail: String {
        let effect: String
        switch viewModel.fnKeySystemAction {
        case .showEmojiAndSymbols: effect = "open the emoji picker"
        case .startDictation: effect = "start Apple Dictation"
        case .changeInputSource: effect = "switch your keyboard language"
        default: effect = "trigger a Mac shortcut"
        }
        return "Holding fn may \(effect) as well as dictate. Pick another shortcut, or set fn to Do Nothing in Keyboard Settings."
    }

    private var content: some View {
        HStack(alignment: .top, spacing: BTSpacing.sm + 2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.btWarning)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.btText)
                Text(detail)
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: BTSpacing.sm) {
                    BTButton("Use ⌃⌥Space instead", style: .secondary, action: useAlternative)
                    Button("Open Keyboard Settings", action: openKeyboardSettings)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.btText)
                }
                .padding(.top, 2)
                if let switchError {
                    Text(switchError).font(.btCaption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(BTSpacing.md)
        .background(Color.btWarning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius)
                .stroke(Color.btWarning.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func useAlternative() {
        var state = ShortcutSettingsState()
        let alternative = Self.alternativeShortcut
        guard let shortcut = state.updatePTT(
            keyCode: alternative.keyCode,
            modifiers: alternative.modifiers,
            modifierKeyCode: nil
        ) else {
            switchError = state.shortcutError
            return
        }
        switchError = nil
        viewModel.onUpdatePTTShortcut?(shortcut)
        viewModel.pttShortcutLabel = shortcut.displayString
        viewModel.onTrackOnboardingEvent?("fnConflictSwitchedShortcut", [
            "fnAction": viewModel.fnKeySystemAction.analyticsLabel,
        ])
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        viewModel.onTrackOnboardingEvent?("fnConflictOpenedKeyboardSettings", [
            "fnAction": viewModel.fnKeySystemAction.analyticsLabel,
        ])
    }
}

// MARK: - Practice mic meter

/// Live microphone level for the practice step. Reads the isolated
/// `AudioLevelMeter`, so only this view re-renders at audio rate.
struct PracticeMicMeter: View {
    let meter: AudioLevelMeter
    let isRecording: Bool

    private static let barWeights: [CGFloat] = [0.45, 0.75, 1.0, 0.7, 0.5]

    var body: some View {
        let level = isRecording ? CGFloat(max(0, min(1, meter.level))) : 0
        HStack(spacing: 8) {
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isRecording ? Color.btEmber : Color.btSecondaryText)
            HStack(alignment: .center, spacing: 3) {
                ForEach(Self.barWeights.indices, id: \.self) { index in
                    let boosted = min(1, level * 2.2)
                    Capsule()
                        .fill(isRecording ? Color.btEmber : Color.btBorder)
                        .frame(width: 3, height: max(3, 16 * boosted * Self.barWeights[index]))
                }
            }
            .frame(height: 16)
            Text(isRecording ? "Listening" : "Mic ready")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.btSecondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRecording ? "Microphone is listening" : "Microphone ready")
    }
}

// MARK: - Word reveal

/// Shows text word by word: each word fades and rises in over 200 ms with a short
/// stagger. Under Reduce Motion everything appears at once.
struct WordRevealText: View {
    let text: String
    var font: Font = .btBody
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        let words = WordReveal.words(in: text)
        let stagger = WordReveal.stagger(forWordCount: words.count)
        WordFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(font)
                    .opacity(isRevealed ? 1 : 0)
                    .offset(y: isRevealed || reduceMotion ? 0 : 4)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: WordReveal.wordDuration).delay(Double(index) * stagger),
                        value: isRevealed
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear { isRevealed = true }
    }
}

/// Minimal wrapping layout for word reveal.
struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private struct Item { var index: Int; var x: CGFloat; var size: CGSize }
    private struct Row { var items: [Item] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let x = current.items.isEmpty ? 0 : current.width + spacing
            if !current.items.isEmpty && x + size.width > maxWidth {
                rows.append(current)
                y += current.height + lineSpacing
                current = Row(y: y)
                current.items.append(Item(index: index, x: 0, size: size))
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append(Item(index: index, x: x, size: size))
                current.width = x + size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
