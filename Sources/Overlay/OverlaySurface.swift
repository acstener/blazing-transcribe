import AppKit

public final class OverlaySurface {
    private var panels: [OverlayPanel]
    private var lastStatus: OverlayPanel.Status = .idle
    private var lastAudioLevel: Float = 0

    private init(panels: [OverlayPanel]) {
        self.panels = panels
    }

    public static func create() -> OverlaySurface {
        OverlaySurface(panels: makePanels())
    }

    public func updateAudioLevel(_ level: Float) {
        lastAudioLevel = level
        panels.forEach { $0.updateAudioLevel(level) }
    }

    public func show(status: OverlayPanel.Status) {
        lastStatus = status
        guard Self.isOverlayEnabled else {
            panels.forEach { $0.hideImmediately() }
            return
        }

        panels.forEach { $0.show(status: status) }
    }

    public func hideImmediately() {
        lastStatus = .idle
        panels.forEach { $0.hideImmediately() }
    }

    public func showToast(_ message: String, duration: TimeInterval = 4.0) {
        panels.first?.showToast(message, duration: duration)
    }

    public func dismissToast() {
        panels.first?.dismissToast()
    }

    public func prewarmIfNeeded() {
        panels.forEach { $0.prewarmIfNeeded() }
    }

    public var startupDiagnosticSummary: String {
        panels.enumerated().map { index, panel in
            "panel\(index)=\(panel.startupDiagnosticSummary)"
        }.joined(separator: ",")
    }

    public func reloadConfiguration() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reloadConfiguration()
            }
            return
        }

        panels.forEach { $0.hideImmediately() }

        panels = Self.makePanels()
        prewarmIfNeeded()

        guard case .idle = lastStatus else {
            show(status: lastStatus)
            if case .recording = lastStatus {
                updateAudioLevel(lastAudioLevel)
            }
            return
        }
    }

    private static func makePanels() -> [OverlayPanel] {
        let style = OverlayVisualStyle.current()
        let recipes = activeRecipes(for: style)
        return recipes.enumerated().map { index, recipe in
            let stackIndex = max(0, recipes.count - index - 1)
            return OverlayPanel.create(recipe: recipe, visualStyle: style, stackIndex: stackIndex)
        }
    }

    private static func activeRecipes(for style: OverlayVisualStyle) -> [OverlayGlassRecipe] {
        guard style == .glass,
              #available(macOS 26.0, *),
              OverlayDiagnostics.isCompareModeEnabled else {
            return [.bubblesSubdued]
        }
        return OverlayGlassRecipe.allCases
    }

    private static var isOverlayEnabled: Bool {
        (UserDefaults.standard.object(forKey: "overlayEnabled") as? Bool) ?? true
    }
}
