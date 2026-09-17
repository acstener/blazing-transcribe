import SwiftUI

// MARK: - Spring Configs

extension Animation {
    /// Standard spring — cards, toggles, nav items
    static let btSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// Soft spring — page transitions
    static let btSoft = Animation.spring(response: 0.4, dampingFraction: 0.85)
    /// Snappy spring — fast feedback (buttons, micro-interactions)
    static let btSnappy = Animation.spring(response: 0.2, dampingFraction: 0.65)
}

// MARK: - Hover Effect Modifier

struct BTHoverEffect: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .offset(y: isHovered ? -1 : 0)
            .shadow(
                color: Color.btCardShadow,
                radius: isHovered ? 8 : 4,
                y: isHovered ? 4 : 2
            )
            .animation(.btSpring, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Staggered Appear Modifier

struct BTStaggeredAppear: ViewModifier {
    let index: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(
                .btSoft.delay(Double(index) * 0.02),
                value: appeared
            )
            .onAppear { appeared = true }
    }
}

// MARK: - Button Style

struct BTButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.btSnappy, value: configuration.isPressed)
    }
}

// MARK: - View Extensions

extension View {
    func btHoverEffect() -> some View {
        modifier(BTHoverEffect())
    }

    func btStaggered(index: Int) -> some View {
        modifier(BTStaggeredAppear(index: index))
    }
}
