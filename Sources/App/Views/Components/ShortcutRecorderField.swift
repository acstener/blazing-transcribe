import SwiftUI
import AppKit
import HotkeyModule

struct CapturedShortcut: Equatable {
    let keyCode: UInt32?
    let modifiers: NSEvent.ModifierFlags
    let modifierKeyCode: UInt32?
}

enum ShortcutCaptureAction: Equatable {
    case none
    case cancel
    case capture(CapturedShortcut)
}

struct ShortcutCaptureStateMachine {
    private var pendingModifierRawValue: UInt = 0
    private var pendingModifierKeyCode: UInt32?

    mutating func reset() {
        pendingModifierRawValue = 0
        pendingModifierKeyCode = nil
    }

    mutating func handleKeyDown(keyCode: UInt32, modifierRawValue: UInt) -> ShortcutCaptureAction {
        let modifiers = relevantModifierRawValue(from: modifierRawValue | pendingModifierRawValue)
        if keyCode == 53 && modifiers == 0 {
            reset()
            return .cancel
        }

        reset()
        return .capture(
            CapturedShortcut(
                keyCode: keyCode,
                modifiers: NSEvent.ModifierFlags(rawValue: modifiers),
                modifierKeyCode: nil
            )
        )
    }

    mutating func handleFlagsChanged(keyCode: UInt32, modifierRawValue: UInt) -> CapturedShortcut? {
        let modifiers = relevantModifierRawValue(from: modifierRawValue)

        guard modifiers != 0 else {
            return capturePendingModifiers()
        }

        if pendingModifierRawValue == 0 || isExpansion(from: pendingModifierRawValue, to: modifiers) {
            pendingModifierRawValue = modifiers
            pendingModifierKeyCode = keyCode
            return nil
        }

        if modifiers == pendingModifierRawValue {
            if pendingModifierKeyCode == nil {
                pendingModifierKeyCode = keyCode
            }
            return nil
        }

        return capturePendingModifiers()
    }

    private mutating func capturePendingModifiers() -> CapturedShortcut? {
        guard pendingModifierRawValue != 0 else { return nil }
        let capturedRawValue = pendingModifierRawValue
        let capturedModifierKeyCode = inferredModifierKeyCode(
            for: capturedRawValue,
            fallback: pendingModifierKeyCode
        )
        reset()
        return CapturedShortcut(
            keyCode: nil,
            modifiers: NSEvent.ModifierFlags(rawValue: capturedRawValue),
            modifierKeyCode: capturedModifierKeyCode
        )
    }

    private func relevantModifierRawValue(from rawValue: UInt) -> UInt {
        GlobalShortcut.relevantModifierRawValue(from: rawValue)
    }

    private func isExpansion(from previousRawValue: UInt, to newRawValue: UInt) -> Bool {
        (newRawValue & previousRawValue) == previousRawValue
    }

    private func inferredModifierKeyCode(for rawValue: UInt, fallback: UInt32?) -> UInt32? {
        let normalizedModifiers = GlobalShortcut.normalizedModifierFlags(fromRaw: rawValue)
        let orderedFlags: [NSEvent.ModifierFlags] = [.control, .option, .shift, .command, .function]
        let matchedFlags = orderedFlags.filter { normalizedModifiers.contains($0) }

        guard matchedFlags.count == 1, let modifierFlag = matchedFlags.first else {
            return nil
        }

        switch modifierFlag {
        case .function:
            return 63
        case .command:
            if rawValue & 0x00000008 != 0 { return 55 }
            if rawValue & 0x00000010 != 0 { return 54 }
        case .option:
            if rawValue & 0x00000020 != 0 { return 58 }
            if rawValue & 0x00000040 != 0 { return 61 }
        case .shift:
            if rawValue & 0x00000002 != 0 { return 56 }
            if rawValue & 0x00000004 != 0 { return 60 }
        case .control:
            if rawValue & 0x00000001 != 0 { return 59 }
            if rawValue & 0x00002000 != 0 { return 62 }
        default:
            break
        }

        guard let fallback,
              GlobalShortcut.modifierFlag(forModifierKeyCode: fallback) == modifierFlag else {
            return nil
        }

        return fallback
    }
}

struct ShortcutRecorderField: View {
    let title: String
    let subtitle: String
    let shortcut: String
    let captureHint: String
    let onCapture: (CapturedShortcut) -> Void
    let onReset: () -> Void

    @State private var isRecording = false
    @State private var captureSessionID = UUID()

    var body: some View {
        BTCard {
            VStack(alignment: .leading, spacing: BTSpacing.sm) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: BTSpacing.md) {
                        titleBlock
                        Spacer(minLength: BTSpacing.md)
                        shortcutValueBadge
                        recordButton
                        resetButton
                    }
                    .frame(minWidth: 560, alignment: .leading)

                    VStack(alignment: .leading, spacing: BTSpacing.sm) {
                        titleBlock

                        BTFlowLayout(spacing: BTSpacing.sm, rowSpacing: BTSpacing.sm) {
                            shortcutValueBadge
                            recordButton
                            resetButton
                        }
                    }
                }

                if isRecording {
                    Text(captureHint)
                        .font(.btCaption)
                        .foregroundStyle(Color.btSecondaryText)
                }
            }
        }
        .background(
            ShortcutCaptureBridge(
                isRecording: $isRecording,
                onCapture: onCapture
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                ShortcutCaptureCoordinator.shared.begin(captureSessionID)
            } else {
                ShortcutCaptureCoordinator.shared.end(captureSessionID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutCaptureStateDidChange)) { notification in
            let activeSessionID = notification.userInfo?[ShortcutCaptureNotificationKey.activeSessionID] as? String
            let shouldRecord = activeSessionID == captureSessionID.uuidString
            guard isRecording != shouldRecord else { return }
            isRecording = shouldRecord
        }
        .onDisappear {
            isRecording = false
            ShortcutCaptureCoordinator.shared.end(captureSessionID)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.btBody)
                .foregroundStyle(Color.btText)
            Text(subtitle)
                .font(.btCaption)
                .foregroundStyle(Color.btSecondaryText)
        }
    }

    private var shortcutValueBadge: some View {
        Text(isRecording ? "Recording..." : shortcut)
            .font(.btMono)
            .foregroundStyle(isRecording ? Color.btText : Color.btSecondaryText)
            .padding(.horizontal, BTSpacing.sm)
            .padding(.vertical, BTSpacing.xs)
            .background(isRecording ? Color.btBorder : Color.btActiveBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var recordButton: some View {
        BTButton(isRecording ? "Cancel" : "Record", style: .secondary) {
            isRecording.toggle()
        }
    }

    private var resetButton: some View {
        BTButton("Reset", style: .secondary) {
            isRecording = false
            onReset()
        }
    }
}

private struct ShortcutCaptureBridge: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (CapturedShortcut) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureResponderView {
        let view = ShortcutCaptureResponderView()
        view.onCapture = { shortcut in
            onCapture(shortcut)
        }
        view.onCancel = {
            isRecording = false
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureResponderView, context: Context) {
        nsView.onCapture = { shortcut in
            onCapture(shortcut)
            isRecording = false
        }
        nsView.onCancel = {
            isRecording = false
        }
        nsView.isRecording = isRecording
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class ShortcutCaptureResponderView: NSView {
    var onCapture: ((CapturedShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if !isRecording {
                captureState.reset()
            }
            updateEventMonitors()
        }
    }

    private var captureState = ShortcutCaptureStateMachine()
    private var localKeyDownMonitor: Any?
    private var localFlagsChangedMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    deinit {
        removeEventMonitors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateEventMonitors()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }

        if captureKeyDown(event) {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !captureKeyDown(event) else { return }
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard !captureFlagsChanged(event) else { return }
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
    }

    @discardableResult
    private func captureKeyDown(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        switch captureState.handleKeyDown(
            keyCode: UInt32(event.keyCode),
            modifierRawValue: event.modifierFlags.rawValue
        ) {
        case .none:
            return false
        case .cancel:
            onCancel?()
            return true
        case .capture(let shortcut):
            onCapture?(shortcut)
            return true
        }
    }

    @discardableResult
    private func captureFlagsChanged(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if let shortcut = captureState.handleFlagsChanged(
            keyCode: UInt32(event.keyCode),
            modifierRawValue: event.modifierFlags.rawValue
        ) {
            onCapture?(shortcut)
        }
        return true
    }

    private func updateEventMonitors() {
        guard isRecording, localKeyDownMonitor == nil, localFlagsChangedMonitor == nil else {
            if !isRecording {
                removeEventMonitors()
            }
            return
        }

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.isRecording, event.window == self.window else { return event }
            return self.captureKeyDown(event) ? nil : event
        }

        localFlagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            guard self.isRecording, event.window == self.window else { return event }
            return self.captureFlagsChanged(event) ? nil : event
        }
    }

    private func removeEventMonitors() {
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }

        if let localFlagsChangedMonitor {
            NSEvent.removeMonitor(localFlagsChangedMonitor)
            self.localFlagsChangedMonitor = nil
        }
    }
}
