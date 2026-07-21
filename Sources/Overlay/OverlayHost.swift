import AppKit
import SwiftUI

enum OverlayLayout {
    // Compact baseline pill that can still grow for longer statuses when needed.
    static let glassSize = NSSize(width: 184, height: 40)
    /// Slightly less than height/2 to avoid SDF precision artifacts at the
    /// exact tangent point where the flat edge meets the curve.
    static let glassCornerRadius: CGFloat = 16
    static let glassContentInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    static let bottomDockOffset: CGFloat = 24
    static let comparePanelSpacing: CGFloat = 54
    static let maximumTextWidth: CGFloat = 128
}

enum OverlayGlassRecipe: String, CaseIterable {
    case bubblesBase
    case bubblesScrim
    case bubblesSubdued

    var usesClearStyle: Bool {
        true
    }

    var tintColor: NSColor? {
        nil
    }

    var fillColor: NSColor? {
        NSColor.white.withAlphaComponent(0.03)
    }

    var borderColor: NSColor {
        NSColor.white.withAlphaComponent(0.22)
    }

    var highlightColors: [CGColor] {
        [
            NSColor.white.withAlphaComponent(0.24).cgColor,
            NSColor.white.withAlphaComponent(0.075).cgColor,
            NSColor.clear.cgColor,
        ]
    }

    var shadowOpacity: CGFloat {
        0.2
    }

    var shadowRadius: CGFloat {
        22
    }

    var shadowYOffset: CGFloat {
        -8
    }

    var compareLabel: String {
        switch self {
        case .bubblesBase:
            return "top = bubbles / variant 11 / base"
        case .bubblesScrim:
            return "middle = bubbles / variant 11 / scrim"
        case .bubblesSubdued:
            return "bottom = bubbles / variant 11 / subdued"
        }
    }

    var compareBadge: String {
        switch self {
        case .bubblesBase:
            return "V11 Base"
        case .bubblesScrim:
            return "V11 Scrim"
        case .bubblesSubdued:
            return "V11 Subdued"
        }
    }

    var privateGlassTuning: OverlayPrivateGlassTuning {
        switch self {
        case .bubblesBase:
            return OverlayPrivateGlassTuning(variant: 11, scrimState: 0, subduedState: 0)
        case .bubblesScrim:
            return OverlayPrivateGlassTuning(variant: 11, scrimState: 1, subduedState: 0)
        case .bubblesSubdued:
            return OverlayPrivateGlassTuning(variant: 11, scrimState: 0, subduedState: 1)
        }
    }

    var borderWidth: CGFloat {
        1.0
    }
}

protocol OverlayHosting: AnyObject {
    var rootView: NSView { get }
    var contentHostingView: NSView { get }
    func reapplyGlassTuning()
}

final class SwiftUIOverlayHost: OverlayHosting {
    let hostingView: NSHostingView<OverlayContentView>

    init(viewModel: OverlayViewModel, visualStyle: OverlayVisualStyle) {
        hostingView = NSHostingView(rootView: OverlayContentView(viewModel: viewModel, visualStyle: visualStyle))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
    }

    var rootView: NSView { hostingView }
    var contentHostingView: NSView { hostingView }

    func reapplyGlassTuning() {}
}

@available(macOS 26.0, *)
final class NativeGlassOverlayHost: OverlayHosting {
    private let root: NSView
    private let glassView: NSGlassEffectView
    private let glassTuning: OverlayPrivateGlassTuning?
    private let glassContext: String
    let hostingView: NSHostingView<OverlayContentView>

    init(viewModel: OverlayViewModel, recipe: OverlayGlassRecipe, visualStyle: OverlayVisualStyle) {
        glassTuning = recipe.privateGlassTuning
        glassContext = recipe.rawValue

        let contentContainer = NSView(frame: NSRect(origin: .zero, size: OverlayLayout.glassSize))
        contentContainer.translatesAutoresizingMaskIntoConstraints = true
        contentContainer.autoresizingMask = [.width, .height]

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = .clear
        contentContainer.layer?.borderWidth = 0

        hostingView = NSHostingView(rootView: OverlayContentView(viewModel: viewModel, visualStyle: visualStyle))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        hostingView.layer?.borderWidth = 0
        // `sceneBridgingOptions` only bridges SwiftUI scene chrome such as titles
        // and toolbars. The overlay has no scene chrome, so keep bridging disabled.
        hostingView.sceneBridgingOptions = []

        contentContainer.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: OverlayLayout.glassContentInsets.left),
            hostingView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -OverlayLayout.glassContentInsets.right),
            hostingView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: OverlayLayout.glassContentInsets.top),
            hostingView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -OverlayLayout.glassContentInsets.bottom),
        ])

        glassView = OverlayGlassChromeView.makePureGlassView(recipe: recipe, contentView: contentContainer)

        if OverlayDiagnostics.usePureGlassHost {
            let clipView = OverlayGlassEdgeClipView(frame: NSRect(origin: .zero, size: OverlayLayout.glassSize))
            glassView.translatesAutoresizingMaskIntoConstraints = false
            clipView.addSubview(glassView)
            NSLayoutConstraint.activate([
                glassView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
                glassView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
                glassView.topAnchor.constraint(equalTo: clipView.topAnchor),
                glassView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            ])
            root = clipView
        } else {
            root = OverlayGlassChromeView(recipe: recipe, glassView: glassView)
        }
    }

    var rootView: NSView { root }
    var contentHostingView: NSView { hostingView }

    func reapplyGlassTuning() {
        OverlayPrivateGlassAPI.apply(to: glassView, tuning: glassTuning, context: glassContext)
    }

    func dumpLayerTree(reason: String) {
        print("[OverlayLayerDump] reason=\(reason)")
        dumpView(root, indent: 0)
    }

    private func dumpView(_ view: NSView, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let cls = String(describing: type(of: view))
        let frame = view.frame
        let l = view.layer
        let borderW = l?.borderWidth ?? -1
        let cornerR = l?.cornerRadius ?? -1
        let bgColor = l?.backgroundColor
        let borderC = l?.borderColor
        let masksToBounds = l?.masksToBounds ?? false
        let hasLayer = l != nil

        let bgDesc = describeColor(bgColor)
        let borderCDesc = describeColor(borderC)

        // Flag any view with a non-zero border
        let flag = (borderW > 0) ? " ⚠️ BORDER" : ""

        print("\(pad)[\(cls)] frame=\(Int(frame.width))x\(Int(frame.height)) layer=\(hasLayer) border=\(String(format: "%.1f", borderW)) corner=\(String(format: "%.0f", cornerR)) mask=\(masksToBounds) bg=\(bgDesc) borderColor=\(borderCDesc)\(flag)")

        // Also dump sublayers that don't correspond to subviews
        if let sublayers = l?.sublayers {
            let viewLayers = Set(view.subviews.compactMap { $0.layer })
            for sl in sublayers where !viewLayers.contains(sl) {
                let slCls = String(describing: type(of: sl))
                let slBorderW = sl.borderWidth
                let slCornerR = sl.cornerRadius
                let slFlag = (slBorderW > 0) ? " ⚠️ BORDER" : ""
                print("\(pad)  (sublayer: \(slCls)) border=\(String(format: "%.1f", slBorderW)) corner=\(String(format: "%.0f", slCornerR)) mask=\(sl.masksToBounds) frame=\(Int(sl.frame.width))x\(Int(sl.frame.height))\(slFlag)")
            }
        }

        for sub in view.subviews {
            dumpView(sub, indent: indent + 1)
        }
    }

    private func describeColor(_ cgColor: CGColor?) -> String {
        guard let cgColor else { return "nil" }
        let comps = cgColor.components ?? []
        let alpha = cgColor.alpha
        if alpha == 0 { return "clear" }
        if comps.count >= 3 {
            return String(format: "rgba(%.0f,%.0f,%.0f,%.2f)", comps[0] * 255, comps[1] * 255, comps[2] * 255, alpha)
        }
        // Grayscale or other color space
        let white = comps.first ?? 0
        return String(format: "gray(%.0f,%.2f)", white * 255, alpha)
    }
}

@available(macOS 26.0, *)
private final class OverlayGlassChromeView: NSView {
    private let glassView: NSGlassEffectView
    private let fillView = NSView()
    private let highlightView = OverlayGradientView()
    private let borderView = NSView()

    static func makePureGlassView(recipe: OverlayGlassRecipe, contentView: NSView) -> NSGlassEffectView {
        let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: OverlayLayout.glassSize))
        glassView.style = recipe.usesClearStyle ? .clear : .regular
        glassView.cornerRadius = OverlayLayout.glassCornerRadius
        glassView.tintColor = recipe.tintColor
        // Do NOT set clipsToBounds — NSGlassEffectView ignores layer.cornerRadius,
        // so clipsToBounds clips to a rectangle, leaving a visible rectangular edge.
        // The SDF layer already renders the pill shape; no additional clipping needed.
        glassView.contentView = contentView
        let glassTuning = recipe.privateGlassTuning
        OverlayPrivateGlassAPI.apply(to: glassView, tuning: glassTuning, context: recipe.rawValue)
        return glassView
    }

    init(recipe: OverlayGlassRecipe, glassView: NSGlassEffectView) {
        self.glassView = glassView
        super.init(frame: NSRect(origin: .zero, size: OverlayLayout.glassSize))

        wantsLayer = true
        layer?.backgroundColor = .clear
        layer?.borderWidth = 0
        layer?.shadowColor = NSColor.black.withAlphaComponent(recipe.shadowOpacity).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = recipe.shadowRadius
        layer?.shadowOffset = CGSize(width: 0, height: recipe.shadowYOffset)
        layer?.masksToBounds = false

        glassView.translatesAutoresizingMaskIntoConstraints = false

        fillView.translatesAutoresizingMaskIntoConstraints = false
        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = recipe.fillColor?.cgColor ?? NSColor.clear.cgColor
        fillView.layer?.cornerRadius = OverlayLayout.glassCornerRadius
        fillView.layer?.cornerCurve = .continuous

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.configure(colors: recipe.highlightColors)

        borderView.translatesAutoresizingMaskIntoConstraints = false
        borderView.wantsLayer = true
        borderView.layer?.backgroundColor = .clear
        borderView.layer?.borderColor = recipe.borderColor.cgColor
        borderView.layer?.borderWidth = recipe.borderWidth
        borderView.layer?.cornerRadius = OverlayLayout.glassCornerRadius
        borderView.layer?.cornerCurve = .continuous

        addSubview(glassView)
        addSubview(fillView)
        addSubview(highlightView)
        addSubview(borderView)

        // Chrome layers are available for design tuning but disabled by default.
        // Enable via `defaults write ... overlayPureGlassMode -bool NO`.
        fillView.isHidden = true
        highlightView.isHidden = true
        borderView.isHidden = true
        layer?.shadowOpacity = 0

        let views = [glassView, fillView, highlightView, borderView]
        NSLayoutConstraint.activate(views.flatMap { view in
            [
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let r = min(OverlayLayout.glassCornerRadius, bounds.height / 2)
        // Only configure chrome layers when they're visible to avoid redundant
        // rounded-corner compositing surfaces that produce edge artifacts.
        guard !fillView.isHidden else { return }
        fillView.layer?.cornerRadius = r
        borderView.layer?.cornerRadius = r
        layer?.cornerRadius = r
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
    }
}

@available(macOS 26.0, *)
private final class OverlayGradientView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CAGradientLayer()
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(colors: [CGColor]) {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = colors
        gradient.locations = [0, 0.45, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = OverlayLayout.glassCornerRadius
        layer?.cornerCurve = .continuous
    }
}

/// Thin wrapper that applies a 1pt-inset rounded mask to clip away
/// sub-pixel dark fringe artifacts from NSGlassEffectView's SDF rendering.
@available(macOS 26.0, *)
private final class OverlayGlassEdgeClipView: NSView {
    private static let inset: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let mask = CAShapeLayer()
        let clipped = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let r = max(1, OverlayLayout.glassCornerRadius - Self.inset)
        mask.path = CGPath(roundedRect: clipped, cornerWidth: r, cornerHeight: r, transform: nil)
        layer?.mask = mask
    }
}
