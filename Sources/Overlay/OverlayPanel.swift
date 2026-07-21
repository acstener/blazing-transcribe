import AppKit
import SwiftUI

// MARK: - Overlay Panel

/// Non-focus-stealing floating overlay panel that shows transcription status.
public final class OverlayPanel: NSPanel {
    public enum Status {
        case idle
        case muted           // Mic explicitly muted via toggle shortcut
        case listening
        case arming
        case recording       // Active manual recording (PTT / toggle)
        case transcribing
        case hearing
        case downloading     // Model download in progress
        case loading         // Model loading / compilation (already on disk)
        case partial(String, confirmed: Bool)
        case result(String)
        case warning(String)  // Non-fatal notice (e.g. cleanup fell back, slow transcription)
        case error(String)
    }

    private let viewModel = OverlayViewModel()
    private let recipe: OverlayGlassRecipe
    private let visualStyle: OverlayVisualStyle
    private let stackIndex: Int
    private var overlayHost: OverlayHosting!
    private var hideTimer: Timer?
    private var isShowingRecording = false
    private let minimumVisibleDuration: TimeInterval = 0.45
    private var minimumVisibleUntil: Date?
    private var usesLiquidGlass: Bool = false
    private var showGeneration: UInt = 0
    private var lastRenderedPartial: (text: String, confirmed: Bool)?
    private var pendingPartial: (text: String, confirmed: Bool)?
    private var pendingPartialWorkItem: DispatchWorkItem?
    private var lastPartialRenderAt: CFAbsoluteTime = 0
    private let partialThrottleInterval: CFAbsoluteTime = 1.0 / 20.0
    private let forceKeyWindowAppearance = OverlayDiagnostics.forceKeyWindowAppearance
    private var glassTuningStale = false
    private var activationObserver: Any?
    private var hasCompletedInitialWarmup = false
    private var isInitialWarmupInProgress = false
    private var pendingStatusAfterWarmup: Status?
    private var toastPanel: NSPanel?
    private var toastHideTimer: Timer?

    init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool,
        recipe: OverlayGlassRecipe = .bubblesSubdued,
        visualStyle: OverlayVisualStyle = .glass,
        stackIndex: Int = 0
    ) {
        self.recipe = recipe
        self.visualStyle = visualStyle
        self.stackIndex = stackIndex
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        if #available(macOS 26.0, *), visualStyle == .glass {
            usesLiquidGlass = true
        }

        setupPanel()
        setupViews()
    }

    /// Convenience initializer to create a properly configured overlay.
    static func create(
        recipe: OverlayGlassRecipe = .bubblesSubdued,
        visualStyle: OverlayVisualStyle = .glass,
        stackIndex: Int = 0
    ) -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: OverlayLayout.glassSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            recipe: recipe,
            visualStyle: visualStyle,
            stackIndex: stackIndex
        )
        panel.positionAtBottomCenter()
        return panel
    }

    private func setupPanel() {
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        appearance = nil
        alphaValue = 1
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        OverlayPrivateGlassAPI.apply(to: self)
        overlayLog("setupPanel diagnostics=\(OverlayDiagnostics.summary)")

        if usesLiquidGlass {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.glassTuningStale = true
                self.refreshLiquidGlass(reason: "activate", schedulePostOrderPass: true)
                self.overlayLog("reapply-on-activate \(self.debugStateSummary())")
            }
        }
    }

    deinit {
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public override var canBecomeKey: Bool { forceKeyWindowAppearance }

    public override var canBecomeMain: Bool { forceKeyWindowAppearance }

    private func setupViews() {
        if #available(macOS 26.0, *), usesLiquidGlass {
            overlayHost = NativeGlassOverlayHost(viewModel: viewModel, recipe: recipe, visualStyle: visualStyle)
        } else {
            overlayHost = SwiftUIOverlayHost(viewModel: viewModel, visualStyle: visualStyle)
        }

        contentView = overlayHost.rootView
        setContentSize(OverlayLayout.glassSize)
        overlayHost.rootView.appearance = nil
        overlayHost.contentHostingView.appearance = nil
        overlayHost.rootView.alphaValue = 1
        alphaValue = 1
        viewModel.colorScheme = OverlayViewModel.currentSystemColorScheme()
        viewModel.compareBadgeText = usesLiquidGlass && OverlayDiagnostics.isCompareModeEnabled ? recipe.compareBadge : nil
        overlayLog("setupViews liquid=\(usesLiquidGlass) style=\(visualStyle.rawValue) recipe=\(recipe.rawValue) compare=\"\(recipe.compareLabel)\"")
    }

    /// Feed live audio level (0.0–1.0) to animate the waveform while recording.
    public func updateAudioLevel(_ level: Float) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateAudioLevel(level)
            }
            return
        }

        guard isShowingRecording else { return }
        viewModel.audioLevel = level
        viewModel.updateRecordingIndicators()
    }

    /// Update the overlay status.
    public func show(status: Status) {
        guard Thread.isMainThread else {
            let forwardedStatus = statusSummary(status)
            overlayLog("show-forward-main status=\(forwardedStatus)")
            DispatchQueue.main.async { [weak self] in
                self?.show(status: status)
            }
            return
        }

        if usesLiquidGlass, isInitialWarmupInProgress {
            overlayLog("overlay-warmup-hit status=\(statusSummary(status)) state=\(warmupStateSummary()) action=queue")
            pendingStatusAfterWarmup = status
            return
        }

        if usesLiquidGlass,
           !hasCompletedInitialWarmup,
           !matchesIdle(status) {
            overlayLog("overlay-warmup-hit status=\(statusSummary(status)) state=\(warmupStateSummary()) action=start")
            pendingStatusAfterWarmup = status
            startInitialWarmup()
            return
        }

        render(status: status, allowPartialThrottle: true)
    }

    public var startupDiagnosticSummary: String {
        if Thread.isMainThread {
            return warmupStateSummary()
        }

        var summary = "unknown"
        DispatchQueue.main.sync { [weak self] in
            summary = self?.warmupStateSummary() ?? "unknown"
        }
        return summary
    }

    func prewarmIfNeeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.prewarmIfNeeded()
            }
            return
        }

        guard usesLiquidGlass, !hasCompletedInitialWarmup, !isInitialWarmupInProgress else { return }
        startInitialWarmup()
    }

    func hideImmediately() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.hideImmediately()
            }
            return
        }

        hideTimer?.invalidate()
        hideTimer = nil
        cancelPendingPartialWork()
        pendingStatusAfterWarmup = nil
        minimumVisibleUntil = nil
        isShowingRecording = false
        viewModel.isPresented = false
        viewModel.status = .idle
        glassTuningStale = false
        alphaValue = 1
        if isVisible {
            orderOut(nil)
        }
    }

    // MARK: - Present / Dismiss

    private func present() {
        if isVisible {
            // Replace any in-flight dismiss animation via animator proxy.
            // Direct alphaValue = 1 does NOT work — the dismiss animation overrides it.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                self.animator().alphaValue = 1
            }
            viewModel.isPresented = true
            viewModel.colorScheme = OverlayViewModel.currentSystemColorScheme()
            let needsGlassRefresh = usesLiquidGlass && glassTuningStale
            bringToFront()
            if needsGlassRefresh {
                refreshLiquidGlass(reason: "present-visible", schedulePostOrderPass: false)
            }
            overlayLog("present-visible[\(showGeneration)] refreshed \(debugStateSummary())")
            return
        }

        viewModel.colorScheme = OverlayViewModel.currentSystemColorScheme()
        overlayLog("present-start[\(showGeneration)] \(debugStateSummary())")
        overlayLog("glass-color-scheme=\(viewModel.colorScheme == .dark ? "dark" : "light") recipe=\(recipe.rawValue)")
        positionAtBottomCenter()

        if !usesLiquidGlass {
            overlayHost.reapplyGlassTuning()
            OverlayPrivateGlassAPI.apply(to: self)
            glassTuningStale = false
            viewModel.presentationID &+= 1
            appearance = NSApp.effectiveAppearance
        } else {
            appearance = nil
        }

        viewModel.isPresented = true

        if usesLiquidGlass {
            // Liquid glass: present at full alpha so the window server always
            // provides backdrop samples. Alpha 0 → 1 animations starve the glass
            // compositor — it has no backdrop to blur, causing the "flat" look.
            alphaValue = 1
            bringToFront()
            refreshLiquidGlass(reason: "present-start", schedulePostOrderPass: true)
        } else {
            alphaValue = 0
            bringToFront()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }
        overlayLog("present-visible[\(showGeneration)] \(debugStateSummary())")
    }

    private func dismiss() {
        guard isVisible else {
            viewModel.isPresented = false
            viewModel.status = .idle
            return
        }

        let dismissGeneration = showGeneration
        glassTuningStale = true
        overlayLog("dismiss-start[\(showGeneration)] alpha=\(String(format: "%.2f", alphaValue)) \(debugStateSummary())")
        viewModel.isPresented = false

        if usesLiquidGlass {
            // Liquid glass: skip alpha animation to avoid starving the glass
            // compositor. Just order out immediately — matches Dock behavior.
            orderOut(nil)
            alphaValue = 1
            glassTuningStale = false
            viewModel.status = .idle
            overlayLog("dismiss-hidden[\(showGeneration)] \(debugStateSummary())")
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                guard self.showGeneration == dismissGeneration else {
                    self.overlayLog("dismiss-cancelled[\(dismissGeneration)] superseded by gen \(self.showGeneration), restoring alpha")
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0
                        self.animator().alphaValue = 1
                    }
                    return
                }
                self.orderOut(nil)
                self.alphaValue = 1
                self.glassTuningStale = false
                self.viewModel.status = .idle
                self.overlayLog("dismiss-hidden[\(self.showGeneration)] \(self.debugStateSummary())")
            })
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        let minimumDelay = max(0, (minimumVisibleUntil ?? .distantPast).timeIntervalSinceNow)
        let finalDelay = max(delay, minimumDelay)
        hideTimer = Timer.scheduledTimer(withTimeInterval: finalDelay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    /// Position at the bottom center of the main screen.
    private func positionAtBottomCenter() {
        guard let screen = targetScreen() else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + OverlayLayout.bottomDockOffset + CGFloat(stackIndex) * OverlayLayout.comparePanelSpacing
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func targetScreen() -> NSScreen? {
        if isVisible, let screen {
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return pointerScreen
        }

        if let screen {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private func bringToFront() {
        if forceKeyWindowAppearance {
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }

    private func startInitialWarmup() {
        guard usesLiquidGlass, !hasCompletedInitialWarmup, !isInitialWarmupInProgress else { return }
        guard let screen = targetScreen() else { return }

        isInitialWarmupInProgress = true
        viewModel.colorScheme = OverlayViewModel.currentSystemColorScheme()
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY - frame.height - 24 - CGFloat(stackIndex) * OverlayLayout.comparePanelSpacing
        setFrameOrigin(NSPoint(x: x, y: y))
        alphaValue = 1
        bringToFront()
        refreshLiquidGlass(reason: "warmup", schedulePostOrderPass: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            if self.isVisible {
                self.orderOut(nil)
            }
            self.alphaValue = 1
            self.positionAtBottomCenter()
            self.hasCompletedInitialWarmup = true
            self.isInitialWarmupInProgress = false
            self.overlayLog("warmup-complete \(self.debugStateSummary())")

            if let pendingStatus = self.pendingStatusAfterWarmup {
                self.pendingStatusAfterWarmup = nil
                self.show(status: pendingStatus)
            }
        }
    }

    private func warmupStateSummary() -> String {
        guard usesLiquidGlass else { return "disabled" }
        if hasCompletedInitialWarmup { return "ready" }
        if isInitialWarmupInProgress { return "warming" }
        if pendingStatusAfterWarmup != nil { return "pending" }
        return "cold"
    }

    private func matchesIdle(_ status: Status) -> Bool {
        if case .idle = status {
            return true
        }
        return false
    }

    private func refreshLiquidGlass(reason: String, schedulePostOrderPass: Bool) {
        guard usesLiquidGlass else { return }

        overlayHost.contentHostingView.layoutSubtreeIfNeeded()
        overlayHost.rootView.layoutSubtreeIfNeeded()
        overlayHost.rootView.displayIfNeeded()
        displayIfNeeded()
        overlayHost.reapplyGlassTuning()
        OverlayPrivateGlassAPI.apply(to: self)
        glassTuningStale = false

        guard schedulePostOrderPass else { return }

        let generation = showGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, self.showGeneration == generation else { return }
            self.overlayHost.contentHostingView.layoutSubtreeIfNeeded()
            self.overlayHost.rootView.layoutSubtreeIfNeeded()
            self.overlayHost.rootView.displayIfNeeded()
            self.displayIfNeeded()
            self.overlayHost.reapplyGlassTuning()
            OverlayPrivateGlassAPI.apply(to: self)
            self.glassTuningStale = false
            self.overlayLog("glass-refresh[\(generation)] reason=\(reason) \(self.debugStateSummary())")

            // Dump the full layer tree so we can identify the rectangular border
            if #available(macOS 26.0, *), let glassHost = self.overlayHost as? NativeGlassOverlayHost {
                glassHost.dumpLayerTree(reason: "post-refresh-\(reason)")
            }
        }
    }

    private func overlayLog(_ message: String) {
        print("[Overlay:\(recipe.rawValue)] \(message)")
    }

    private func statusSummary(_ status: Status) -> String {
        switch status {
        case .idle:
            return "idle"
        case .muted:
            return "muted"
        case .listening:
            return "listening"
        case .arming:
            return "arming"
        case .recording:
            return "recording"
        case .transcribing:
            return "transcribing"
        case .hearing:
            return "hearing"
        case .downloading:
            return "downloading"
        case .loading:
            return "loading"
        case .partial(let text, let confirmed):
            return "partial(len=\(text.count),confirmed=\(confirmed))"
        case .result(let text):
            return "result(len=\(text.count))"
        case .warning(let message):
            return "warning(len=\(message.count))"
        case .error(let message):
            return "error(len=\(message.count))"
        }
    }

    private func debugStateSummary() -> String {
        let appearanceName = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
        let hostAlpha = String(format: "%.3f", overlayHost.rootView.alphaValue)
        let windowAlpha = String(format: "%.2f", alphaValue)
        let origin = "(\(Int(frame.origin.x)),\(Int(frame.origin.y)))"
        return "state{visible=\(isVisible),presented=\(viewModel.isPresented),ordered=\(windowNumber != 0),origin=\(origin),hostAlpha=\(hostAlpha),alpha=\(windowAlpha),appearance=\(appearanceName)}"
    }

    private func render(status: Status, allowPartialThrottle: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil

        if allowPartialThrottle, case .partial(let text, let confirmed) = status,
           handlePartialThrottle(text: text, confirmed: confirmed) {
            return
        }

        if case .partial = status {
            pendingPartial = nil
        } else {
            cancelPendingPartialWork()
            lastRenderedPartial = nil
            lastPartialRenderAt = 0
        }

        showGeneration &+= 1
        let wasVisible = isVisible
        let previousStatus = statusSummary(viewModel.status)
        overlayLog("show[\(showGeneration)] status=\(statusSummary(status)) prev=\(previousStatus) wasVisible=\(wasVisible) \(debugStateSummary())")

        isShowingRecording = false

        switch status {
        case .idle:
            let delay = max(0, (minimumVisibleUntil ?? .distantPast).timeIntervalSinceNow)
            if delay > 0 {
                scheduleHide(after: delay)
            } else {
                dismiss()
            }
            return

        case .muted:
            viewModel.status = .muted
            scheduleHide(after: 2.0)

        case .recording:
            isShowingRecording = true
            viewModel.resetAudioLevel()
            viewModel.status = .recording

        case .result(let text):
            viewModel.status = .result(text)
            scheduleHide(after: 3.0)

        case .warning(let message):
            viewModel.status = .warning(message)
            scheduleHide(after: 5.0)

        case .error(let message):
            viewModel.status = .error(message)
            scheduleHide(after: 5.0)

        case .partial(let text, let confirmed):
            viewModel.status = .partial(text, confirmed: confirmed)
            lastRenderedPartial = (text, confirmed)
            lastPartialRenderAt = CFAbsoluteTimeGetCurrent()

        default:
            viewModel.status = status
        }

        if !wasVisible {
            minimumVisibleUntil = Date().addingTimeInterval(minimumVisibleDuration)
        }

        overlayHost.contentHostingView.layoutSubtreeIfNeeded()
        overlayHost.rootView.layoutSubtreeIfNeeded()

        let fitting = overlayHost.contentHostingView.fittingSize
        let extraWidth = usesLiquidGlass
            ? OverlayLayout.glassContentInsets.left + OverlayLayout.glassContentInsets.right
            : 0
        let extraHeight = usesLiquidGlass
            ? OverlayLayout.glassContentInsets.top + OverlayLayout.glassContentInsets.bottom
            : 0
        let size = NSSize(
            width: max(OverlayLayout.glassSize.width, ceil(fitting.width + extraWidth)),
            height: max(OverlayLayout.glassSize.height, ceil(fitting.height + extraHeight))
        )
        setContentSize(size)
        positionAtBottomCenter()

        present()
    }

    private func handlePartialThrottle(text: String, confirmed: Bool) -> Bool {
        let isOverlayVisible = isVisible
        guard isOverlayVisible else { return false }

        if isOverlayVisible, let lastRenderedPartial,
           lastRenderedPartial.text == text, lastRenderedPartial.confirmed == confirmed {
            overlayLog("partial-skip duplicate len=\(text.count) confirmed=\(confirmed)")
            return true
        }

        if let pendingPartial,
           pendingPartial.text == text, pendingPartial.confirmed == confirmed {
            overlayLog("partial-skip pending-duplicate len=\(text.count) confirmed=\(confirmed)")
            return true
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard lastPartialRenderAt > 0 else { return false }

        let elapsed = now - lastPartialRenderAt
        guard elapsed < partialThrottleInterval else { return false }

        pendingPartial = (text, confirmed)

        if pendingPartialWorkItem == nil {
            let delay = partialThrottleInterval - elapsed
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingPartialWorkItem = nil
                guard let pending = self.pendingPartial else { return }
                self.pendingPartial = nil
                self.overlayLog("partial-flush len=\(pending.text.count) confirmed=\(pending.confirmed)")
                self.render(status: .partial(pending.text, confirmed: pending.confirmed), allowPartialThrottle: false)
            }
            pendingPartialWorkItem = workItem
            overlayLog("partial-coalesce delay_ms=\(Int(delay * 1000)) len=\(text.count) confirmed=\(confirmed)")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        } else {
            overlayLog("partial-coalesce update len=\(text.count) confirmed=\(confirmed)")
        }

        return true
    }

    private func cancelPendingPartialWork() {
        pendingPartialWorkItem?.cancel()
        pendingPartialWorkItem = nil
        pendingPartial = nil
        lastPartialRenderAt = 0
    }

    // MARK: - Toast (non-disruptive overlay message)

    /// Show a small black pill above the main overlay without interrupting
    /// the current overlay state (e.g. recording waveform stays visible).
    public func showToast(_ message: String, duration: TimeInterval = 4.0) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.showToast(message, duration: duration)
            }
            return
        }

        dismissToast()

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.96)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])

        let fittingSize = label.fittingSize
        let panelSize = NSSize(width: ceil(fittingSize.width) + 24, height: ceil(fittingSize.height) + 12)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = container

        // Position above the main overlay
        let overlayFrame = self.frame
        let x = overlayFrame.midX - panelSize.width / 2
        let y = overlayFrame.maxY + 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        toastPanel = panel

        toastHideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.dismissToast()
        }
    }

    public func dismissToast() {
        toastHideTimer?.invalidate()
        toastHideTimer = nil
        guard let panel = toastPanel else { return }
        toastPanel = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
