import SwiftUI

/// Monochrome segmented control: a neutral `btAccent` thumb slides between
/// segments (matchedGeometryEffect) and the label over it inverts to
/// `btAccentForeground`. Under Reduce Motion the thumb crossfades instead.
///
/// Selection is driven from outside (`selection` + `onSelect`) so callers can
/// route the change through their own model callbacks.
struct BTSegmentedControl<Value: Hashable>: View {
    struct Segment: Identifiable {
        let value: Value
        let title: String
        var icon: String? = nil
        var id: Value { value }
    }

    let segments: [Segment]
    let selection: Value
    let onSelect: (Value) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumbNamespace

    private let cornerRadius: CGFloat = BTSpacing.buttonCornerRadius
    private let inset: CGFloat = 3

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(inset)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.btActiveBackground)
        )
        .animation(.btSelection(reduceMotion: reduceMotion), value: selection)
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.value == selection
        return Button {
            guard !isSelected else { return }
            onSelect(segment.value)
        } label: {
            HStack(spacing: 6) {
                if let icon = segment.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(segment.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.btAccentForeground : Color.btText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background { thumb(isSelected: isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(BTSegmentButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func thumb(isSelected: Bool) -> some View {
        if isSelected {
            let shape = RoundedRectangle(cornerRadius: cornerRadius - inset, style: .continuous)
                .fill(Color.btAccent)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            if reduceMotion {
                shape.transition(.opacity)
            } else {
                shape.matchedGeometryEffect(id: "thumb", in: thumbNamespace)
            }
        }
    }
}

/// Press feedback for segments: a slight dim, no scale (the thumb is a large surface).
private struct BTSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.btSnappy, value: configuration.isPressed)
    }
}

extension Animation {
    /// Selection change for sliding thumbs/highlights: a spring slide, or under
    /// Reduce Motion a short ease-out crossfade.
    static func btSelection(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .btSpring
    }
}
