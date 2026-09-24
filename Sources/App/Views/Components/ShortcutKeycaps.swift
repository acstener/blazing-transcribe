import SwiftUI

/// Splits a shortcut display string (e.g. "⌥ ⌘ M", "fn Space", "Right Command")
/// into the individual keys drawn as separate keycaps.
enum ShortcutKeycapParts {
    static func split(_ display: String) -> [String] {
        let tokens = display
            .split(whereSeparator: { $0.isWhitespace || $0 == "+" })
            .map(String.init)

        var parts: [String] = []
        var pendingSide: String?
        for token in tokens {
            if token == "Left" || token == "Right" {
                if let side = pendingSide { parts.append(side) }
                pendingSide = token
                continue
            }
            if let side = pendingSide {
                parts.append("\(side) \(token)")
                pendingSide = nil
            } else {
                parts.append(token)
            }
        }
        if let side = pendingSide { parts.append(side) }
        return parts
    }
}

/// The user's dictation shortcut drawn as physical keycaps that mirror the real key:
/// they sink while the shortcut is held (Ember border), spring back on release, and
/// shake when a press couldn't start recording.
struct ShortcutKeycaps: View {
    enum Size {
        case regular, compact

        var fontSize: CGFloat { self == .regular ? 18 : 14 }
        var height: CGFloat { self == .regular ? 44 : 32 }
        var minWidth: CGFloat { self == .regular ? 48 : 36 }
        var horizontalPadding: CGFloat { self == .regular ? 16 : 11 }
        var cornerRadius: CGFloat { self == .regular ? 10 : 8 }
    }

    let label: String
    /// Live state: the real shortcut is held (or a toggle recording is active).
    let isPressed: Bool
    /// Bump to play the "couldn't start" shake.
    var rejectionCount: Int = 0
    /// Pointer press on the caps themselves: sinks, but stays neutral (not a live moment).
    var isClickPressed: Bool = false
    var size: Size = .regular

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsRejection = false

    private var parts: [String] { ShortcutKeycapParts.split(label) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("+")
                        .font(.system(size: size.fontSize * 0.7, weight: .regular))
                        .foregroundStyle(Color.btSecondaryText.opacity(0.7))
                        .accessibilityHidden(true)
                }
                Keycap(
                    text: part,
                    size: size,
                    isSunk: isPressed || isClickPressed,
                    isLive: isPressed,
                    showsRejection: showsRejection,
                    reduceMotion: reduceMotion
                )
            }
        }
        .keyframeAnimator(initialValue: 0.0, trigger: rejectionCount) { content, offset in
            content.offset(x: reduceMotion ? 0 : offset)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-6, duration: 0.05)
                LinearKeyframe(6, duration: 0.07)
                LinearKeyframe(-4, duration: 0.06)
                LinearKeyframe(3, duration: 0.06)
                SpringKeyframe(0, duration: 0.14, spring: .snappy)
            }
        }
        .task(id: rejectionCount) {
            guard rejectionCount > 0, reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.15)) { showsRejection = true }
            try? await Task.sleep(for: .seconds(0.7))
            withAnimation(.easeOut(duration: 0.25)) { showsRejection = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcut \(parts.joined(separator: " plus "))")
        .accessibilityValue(isPressed ? "Held" : "")
    }
}

private struct Keycap: View {
    let text: String
    let size: ShortcutKeycaps.Size
    let isSunk: Bool
    let isLive: Bool
    let showsRejection: Bool
    let reduceMotion: Bool

    private let sinkDepth: CGFloat = 2
    private let edgeDepth: CGFloat = 3

    private var borderColor: Color {
        if showsRejection { return .red }
        return isLive ? .btEmber : .btBorder
    }

    /// Press-in is near-instant so it tracks the finger; release springs back.
    private var animation: Animation {
        if reduceMotion { return .easeOut(duration: 0.12) }
        return isSunk ? .easeOut(duration: 0.06) : .btSnappy
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
        // Under Reduce Motion the cap doesn't travel; the edge and border crossfade instead.
        let faceOffset: CGFloat = isSunk && !reduceMotion ? sinkDepth : 0

        Text(text)
            .font(.system(size: size.fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.btText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size.horizontalPadding)
            .frame(minWidth: size.minWidth, minHeight: size.height)
            .background(shape.fill(Color.btCardBackground))
            .overlay(shape.strokeBorder(borderColor, lineWidth: isLive || showsRejection ? 1.5 : 1))
            .offset(y: faceOffset)
            .background(alignment: .top) {
                // The bottom edge: visible below the face at rest, hidden once it sinks.
                shape
                    .fill(Color.btBorder)
                    .offset(y: edgeDepth)
                    .opacity(isSunk ? 0 : 1)
            }
            .padding(.bottom, edgeDepth)
            .animation(animation, value: isSunk)
            .animation(.easeOut(duration: 0.12), value: isLive)
    }
}

/// Button style that renders the shortcut keycaps and lets a click press them too.
struct ShortcutKeycapButtonStyle: ButtonStyle {
    let label: String
    let isPressed: Bool
    var rejectionCount: Int = 0
    var size: ShortcutKeycaps.Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        ShortcutKeycaps(
            label: label,
            isPressed: isPressed,
            rejectionCount: rejectionCount,
            isClickPressed: configuration.isPressed,
            size: size
        )
        .contentShape(Rectangle())
    }
}
