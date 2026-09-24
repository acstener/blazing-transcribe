import SwiftUI

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    /// Flash an Ember underline once under the value (the value changed since the last visit).
    var flash: Bool = false
    var flashDelay: Double = 0

    var body: some View {
        BTCard {
            VStack(alignment: .leading, spacing: BTSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.btSecondaryText)
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.btText)
                    .contentTransition(.numericText())
                    .usageChangeFlash(flash, delay: flashDelay)
                Text(title)
                    .font(.btCaption)
                    .foregroundStyle(Color.btSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Change flash

/// A thin Ember underline that draws in under a value, holds briefly and fades — once.
/// Reduce Motion: a plain fade in/out, no draw.
struct UsageChangeFlash: ViewModifier {
    let active: Bool
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var drawn = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                Capsule()
                    .fill(Color.btEmber)
                    .frame(height: 2)
                    .scaleEffect(x: drawn || reduceMotion ? 1 : 0, anchor: .leading)
                    .opacity(shown ? 1 : 0)
                    .offset(y: 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task(id: active) {
                guard active else { return }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.28)) { shown = true; drawn = true }
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.5)) { shown = false }
            }
    }
}

extension View {
    func usageChangeFlash(_ active: Bool, delay: Double = 0) -> some View {
        modifier(UsageChangeFlash(active: active, delay: delay))
    }
}
