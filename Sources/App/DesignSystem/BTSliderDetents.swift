import SwiftUI

/// A named value a tuning slider can snap to ("Snappy 0.35s").
struct BTSliderDetent: Identifiable, Equatable {
    let name: String
    let value: Double
    var id: String { name }

    /// Label shown when the value sits between detents.
    static let customLabel = "Custom"

    /// The detent the value sits on, or nil when it's between detents.
    /// A small tolerance absorbs slider step rounding (0.2 + 3 × 0.05 ≠ 0.35 exactly).
    static func matching(_ value: Double, in detents: [BTSliderDetent],
                         tolerance: Double = 0.001) -> BTSliderDetent? {
        detents.first { abs($0.value - value) <= tolerance }
    }

    /// The detent's name, or "Custom" between detents.
    static func label(for value: Double, in detents: [BTSliderDetent]) -> String {
        matching(value, in: detents)?.name ?? customLabel
    }
}

/// Row of tappable named detents shown under a slider. Tapping snaps the
/// value; the active detent is bold, and "Custom" appears between detents.
struct BTSliderDetentRow: View {
    let detents: [BTSliderDetent]
    @Binding var value: Double
    /// Formats the detent's value for its tooltip / accessibility hint, e.g. "0.35s".
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        let active = BTSliderDetent.matching(value, in: detents)
        HStack(spacing: BTSpacing.xs) {
            ForEach(Array(detents.enumerated()), id: \.element.id) { index, detent in
                if index > 0 {
                    Text("·")
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText.opacity(0.5))
                }
                detentButton(detent, isActive: detent == active)
            }
            Spacer(minLength: BTSpacing.sm)
            Text(BTSliderDetent.customLabel)
                .font(.btCaption.weight(.semibold))
                .foregroundStyle(Color.btSecondaryText)
                .opacity(active == nil ? 1 : 0)
                .accessibilityHidden(active != nil)
        }
    }

    private func detentButton(_ detent: BTSliderDetent, isActive: Bool) -> some View {
        Button {
            value = detent.value
        } label: {
            Text(detent.name)
                .font(.btCaption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.btText : Color.btSecondaryText)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(BTButtonStyle())
        .help("\(detent.name): \(format(detent.value))")
        .accessibilityLabel(detent.name)
        .accessibilityValue(format(detent.value))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
