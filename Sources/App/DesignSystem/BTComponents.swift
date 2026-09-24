import SwiftUI
import AppKit

// MARK: - Card

struct BTCard<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
            .padding(BTSpacing.md)
            .background(Color.btCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BTSpacing.cardCornerRadius)
                    .stroke(Color.btBorder, lineWidth: 1)
            )

    }
}

// MARK: - Button

struct BTButton: View {
    enum Style {
        case primary
        case secondary
        case destructive
    }

    let title: String
    let style: Style
    let action: () -> Void

    init(_ title: String, style: Style = .primary, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, BTSpacing.md)
                .padding(.vertical, BTSpacing.sm)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
        }
        .buttonStyle(BTButtonStyle())
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: return .btBackground
        case .secondary: return .btText
        case .destructive: return .white
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: return Color.btText
        case .secondary: return Color.btActiveBackground
        case .destructive: return .red
        }
    }
}

// MARK: - Text Field

struct BTTextField: View {
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    var body: some View {
        TextField(
            "",
            text: $text,
            prompt: Text(placeholder)
                .foregroundStyle(Color.btSecondaryText)
        )
            .font(isMonospaced ? .btMono : .btBody)
            .foregroundStyle(Color.btText)
            .textFieldStyle(.plain)
            .padding(BTSpacing.sm + 2)
            .background(Color.btBackground)
            .clipShape(RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: BTSpacing.buttonCornerRadius)
                    .stroke(Color.btBorder, lineWidth: 1)
            )
    }
}

// MARK: - Badge

struct BTBadge: View {
    let text: String
    var color: Color = .purple

    var body: some View {
        Text(text)
            .font(.btLabel)
            .padding(.horizontal, BTSpacing.sm)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(color)
            .clipShape(Capsule())
    }
}

// MARK: - Sidebar Item

struct BTSidebarItem: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BTSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.btText : Color.btSecondaryText)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.btText : Color.btSecondaryText)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.btActiveBackground)
                        .matchedGeometryEffect(id: "sidebarPill", in: namespace)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shadow Modifiers

extension View {
    func btShadowSubtle() -> some View {
        shadow(color: .black.opacity(0.03), radius: 4, y: 2)
    }

    func btShadowHover() -> some View {
        shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }

    func btShadowStrong() -> some View {
        shadow(color: .black.opacity(0.1), radius: 12, y: 6)
    }

    func btHideScrollIndicators() -> some View {
        background(BTScrollViewConfigurator())
            .scrollIndicators(.hidden)
    }

    /// Pins a specific window appearance without affecting overlay/panel windows.
    func btWindowAppearance(_ appearanceName: NSAppearance.Name?) -> some View {
        background(BTWindowAppearanceConfigurator(appearanceName: appearanceName))
    }
}

private struct BTScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let rootView = nsView.window?.contentView else { return }
            rootView.btHideAllScrollers()
        }
    }
}

private struct BTWindowAppearanceConfigurator: NSViewRepresentable {
    let appearanceName: NSAppearance.Name?

    func makeNSView(context: Context) -> BTWindowAppearanceView {
        let view = BTWindowAppearanceView()
        view.appearanceName = appearanceName
        return view
    }

    func updateNSView(_ nsView: BTWindowAppearanceView, context: Context) {
        nsView.appearanceName = appearanceName
        nsView.applyAppearance()
    }
}

private final class BTWindowAppearanceView: NSView {
    var appearanceName: NSAppearance.Name?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    func applyAppearance() {
        guard let window else { return }

        let targetAppearance = appearanceName.flatMap(NSAppearance.init(named:))
        guard window.appearance?.name != targetAppearance?.name else { return }
        window.appearance = targetAppearance
    }
}

private extension NSView {
    func btHideAllScrollers() {
        if let scrollView = self as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.isHidden = true
            scrollView.horizontalScroller?.isHidden = true
        }

        for subview in subviews {
            subview.btHideAllScrollers()
        }
    }
}
