import AppKit
import Carbon

// MARK: - GlobalShortcut

/// A shortcut that can include the fn key (which Carbon HotKey cannot handle).
/// When `keyCode` is nil, the shortcut is modifier-only (e.g. fn alone).
public struct GlobalShortcut: Codable, Equatable {
    /// Virtual key code, or nil for modifier-only shortcuts (e.g. fn alone).
    public let keyCode: UInt32?
    /// NSEvent.ModifierFlags.rawValue (includes .function for fn key).
    public let modifiers: UInt
    /// Physical modifier key code for modifier-only shortcuts (e.g. right command).
    public let modifierKeyCode: UInt32?

    public init(keyCode: UInt32?, modifiers: UInt, modifierKeyCode: UInt32? = nil) {
        self.keyCode = keyCode
        self.modifiers = Self.relevantModifierRawValue(from: modifiers)
        self.modifierKeyCode = modifierKeyCode
    }

    public var nsModifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// Whether this is a modifier-only shortcut (e.g. fn alone).
    public var isModifierOnly: Bool {
        keyCode == nil && (modifierKeyCode != nil || !normalizedModifiers.isEmpty)
    }

    public var normalizedModifiers: NSEvent.ModifierFlags {
        Self.normalizedModifierFlags(fromRaw: modifiers)
    }

    /// Human-readable display string (e.g. "fn", "fn Space").
    public var displayString: String {
        if isModifierOnly {
            if let modifierKeyCode,
               normalizedModifiers == Self.modifierFlag(forModifierKeyCode: modifierKeyCode),
               let modifierName = Self.modifierKeyName(modifierKeyCode) {
                return modifierName
            }
            return Self.modifierLabels(fromRaw: modifiers).joined(separator: " ")
        }

        var parts = Self.modifierLabels(fromRaw: modifiers)
        if let keyCode {
            parts.append(Self.keyName(keyCode))
        }
        return parts.joined(separator: " ")
    }

    public var canUseCarbonHotKey: Bool {
        guard keyCode != nil, modifierKeyCode == nil else { return false }
        guard !normalizedModifiers.isEmpty, !normalizedModifiers.contains(.function) else { return false }
        return Self.deviceDependentModifierRawValue(from: modifiers) == 0
    }

    public func matchesKeyEvent(keyCode eventKeyCode: UInt32, modifierRawValue: UInt) -> Bool {
        guard let shortcutKeyCode = keyCode else { return false }
        return shortcutKeyCode == eventKeyCode && Self.modifiersMatch(modifierRawValue, required: modifiers)
    }

    public func conflicts(with other: GlobalShortcut) -> Bool {
        if isModifierOnly != other.isModifierOnly {
            return false
        }

        if isModifierOnly {
            guard normalizedModifiers == other.normalizedModifiers else { return false }
            let selfDeviceBits = Self.deviceDependentModifierRawValue(from: modifiers)
            let otherDeviceBits = Self.deviceDependentModifierRawValue(from: other.modifiers)
            return selfDeviceBits == 0 || otherDeviceBits == 0 || selfDeviceBits == otherDeviceBits
        }

        guard keyCode == other.keyCode else { return false }
        guard normalizedModifiers == other.normalizedModifiers else { return false }

        let selfDeviceBits = Self.deviceDependentModifierRawValue(from: modifiers)
        let otherDeviceBits = Self.deviceDependentModifierRawValue(from: other.modifiers)
        return selfDeviceBits == 0 || otherDeviceBits == 0 || selfDeviceBits == otherDeviceBits
    }

    public static func relevantModifierRawValue(from rawValue: UInt) -> UInt {
        rawValue & relevantModifierMask
    }

    public static func normalizedModifierFlags(fromRaw rawValue: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawValue).intersection(deviceIndependentModifierFlags)
    }

    public static func deviceDependentModifierRawValue(from rawValue: UInt) -> UInt {
        rawValue & deviceDependentModifierMask
    }

    public static func modifiersMatch(_ eventModifierRawValue: UInt, required: UInt) -> Bool {
        let eventRelevant = relevantModifierRawValue(from: eventModifierRawValue)
        let requiredRelevant = relevantModifierRawValue(from: required)

        guard normalizedModifierFlags(fromRaw: eventRelevant) ==
                normalizedModifierFlags(fromRaw: requiredRelevant) else {
            return false
        }

        let requiredDeviceBits = deviceDependentModifierRawValue(from: requiredRelevant)
        if requiredDeviceBits == 0 {
            return true
        }

        return deviceDependentModifierRawValue(from: eventRelevant) == requiredDeviceBits
    }

    public static func modifierFlag(forModifierKeyCode keyCode: UInt32) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 58, 61: return .option
        case 56, 60: return .shift
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    public static func modifierKeyName(_ keyCode: UInt32) -> String? {
        switch keyCode {
        case 54: return "Right Command"
        case 55: return "Left Command"
        case 58: return "Left Option"
        case 61: return "Right Option"
        case 56: return "Left Shift"
        case 60: return "Right Shift"
        case 59: return "Left Control"
        case 62: return "Right Control"
        case 63: return "fn"
        default: return nil
        }
    }

    private static let keyCodeNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
        0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
        0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".",
        0x24: "↩", 0x30: "⇥", 0x31: "Space", 0x33: "⌫", 0x35: "Esc",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
        0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
        0x67: "F11", 0x6F: "F12",
    ]

    static func keyName(_ code: UInt32) -> String {
        keyCodeNames[code] ?? "Key\(code)"
    }

    private static let deviceIndependentModifierFlags: NSEvent.ModifierFlags = [
        .function, .command, .shift, .option, .control
    ]

    private static let leftControlMask: UInt = 0x00000001
    private static let leftShiftMask: UInt = 0x00000002
    private static let rightShiftMask: UInt = 0x00000004
    private static let leftCommandMask: UInt = 0x00000008
    private static let rightCommandMask: UInt = 0x00000010
    private static let leftOptionMask: UInt = 0x00000020
    private static let rightOptionMask: UInt = 0x00000040
    private static let rightControlMask: UInt = 0x00002000
    private static let deviceDependentModifierMask: UInt =
        leftControlMask |
        leftShiftMask |
        rightShiftMask |
        leftCommandMask |
        rightCommandMask |
        leftOptionMask |
        rightOptionMask |
        rightControlMask
    private static let relevantModifierMask: UInt =
        deviceIndependentModifierFlags.rawValue | deviceDependentModifierMask

    private static func modifierLabels(fromRaw rawValue: UInt) -> [String] {
        let flags = normalizedModifierFlags(fromRaw: rawValue)
        var parts: [String] = []

        if rawValue & leftControlMask != 0 {
            parts.append("L⌃")
        } else if rawValue & rightControlMask != 0 {
            parts.append("R⌃")
        } else if flags.contains(.control) {
            parts.append("⌃")
        }

        if rawValue & leftOptionMask != 0 {
            parts.append("L⌥")
        } else if rawValue & rightOptionMask != 0 {
            parts.append("R⌥")
        } else if flags.contains(.option) {
            parts.append("⌥")
        }

        if rawValue & leftShiftMask != 0 {
            parts.append("L⇧")
        } else if rawValue & rightShiftMask != 0 {
            parts.append("R⇧")
        } else if flags.contains(.shift) {
            parts.append("⇧")
        }

        if rawValue & leftCommandMask != 0 {
            parts.append("L⌘")
        } else if rawValue & rightCommandMask != 0 {
            parts.append("R⌘")
        } else if flags.contains(.command) {
            parts.append("⌘")
        }

        if flags.contains(.function) {
            parts.append("fn")
        }

        return parts
    }

    /// Default PTT shortcut: fn alone.
    public static let defaultPTT = GlobalShortcut(
        keyCode: nil,
        modifiers: NSEvent.ModifierFlags.function.rawValue,
        modifierKeyCode: 63
    )

    /// Default toggle shortcut: fn + Space.
    public static let defaultToggle = GlobalShortcut(
        keyCode: 0x31,  // Space
        modifiers: NSEvent.ModifierFlags.function.rawValue
    )

    /// Fixed LLM cleanup toggle shortcut: Command + Shift + L.
    public static let defaultLLMCleanupToggle = GlobalShortcut(
        keyCode: 0x25,  // L
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

}

// MARK: - GlobalShortcutDelegate

public protocol GlobalShortcutDelegate: AnyObject {
    /// Push-to-talk key pressed (start recording).
    func pttDidPress()
    /// Push-to-talk key released (stop recording, transcribe).
    func pttDidRelease()
    /// Push-to-talk cancelled (don't transcribe — e.g. toggle key overrode it).
    func pttDidCancel()
    /// Toggle key pressed (start or stop recording).
    func toggleDidPress()
    /// Mic toggle shortcut pressed.
    func micToggleDidTrigger()
    /// Mode toggle key pressed (switch between always-on and manual).
    func modeToggleDidTrigger()
    /// PTT safety timeout approaching — show a warning to the user.
    func pttDidWarnTimeout(remainingSeconds: Int)
    /// Whether toggle recording is currently active.
    func isToggleRecordingActiveForShortcuts() -> Bool
}

public extension GlobalShortcutDelegate {
    func pttDidCancel() {}
    func micToggleDidTrigger() {}
    func modeToggleDidTrigger() {}
    func pttDidWarnTimeout(remainingSeconds: Int) {}
    func isToggleRecordingActiveForShortcuts() -> Bool { false }
}

// MARK: - CGEvent Tap Callback

/// C-compatible callback for the CGEvent tap. Forwards to the monitor instance.
private func shortcutEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handleEventTap(type: type, event: event)
}

// MARK: - GlobalShortcutMonitor

/// Monitors global keyboard events for PTT and toggle shortcuts.
/// Uses NSEvent monitors for modifier keys and a CGEvent tap for key events
/// (which allows suppressing shortcut keys from reaching the focused app).
/// Handles the fn key which Carbon RegisterEventHotKey cannot detect.
/// Requires Accessibility permission for global monitoring.
public final class GlobalShortcutMonitor {
    public weak var delegate: GlobalShortcutDelegate?
    /// Optional logging hook for production diagnostics. Set to `appLog` or similar.
    public var logHandler: ((String) -> Void)?

    public var pttShortcut: GlobalShortcut
    public var toggleShortcut: GlobalShortcut
    public var micToggleShortcut: GlobalShortcut?
    /// `nil` means use the built-in double-click fn gesture.
    public var modeToggleShortcut: GlobalShortcut?
    /// Whether key-based shortcuts can currently be suppressed safely.
    public private(set) var isKeySuppressionAvailable = false
    /// Whether any configured shortcut depends on keyDown/keyUp monitoring.
    public var hasConfiguredKeyBasedShortcuts: Bool {
        pttShortcut.keyCode != nil ||
        toggleShortcut.keyCode != nil ||
        micToggleShortcut?.keyCode != nil ||
        modeToggleShortcut?.keyCode != nil
    }

    // NSEvent monitors for flagsChanged (modifier keys)
    private var monitors: [Any] = []

    // CGEvent tap for keyDown/keyUp (can suppress events)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var pttActive = false
    private var currentModifierRawValue: UInt = 0
    private var safetyTimer: Timer?
    private var safetyWarningTimer: Timer?
    private let safetyTimeout: TimeInterval = 300.0       // 5 minutes
    private let safetyWarningAt: TimeInterval = 270.0     // 4 min 30s

    /// Grace period before ending PTT on modifier release.
    /// Filters spurious fn flag drops from macOS (globe key behavior, system events).
    private var pttEndGraceTimer: Timer?
    private let pttEndGracePeriod: TimeInterval = 0.05    // 50ms

    // Deduplication: when both CGEvent tap and NSEvent monitors are active,
    // the same key event can arrive twice. Track the last handled event to skip duplicates.
    private var lastKeyDownID: (keyCode: UInt32, time: CFAbsoluteTime) = (.max, 0)
    private var lastKeyUpID: (keyCode: UInt32, time: CFAbsoluteTime) = (.max, 0)
    private var lastFlagsChangedID: (keyCode: UInt32, flags: UInt, time: CFAbsoluteTime) = (.max, 0, 0)
    /// One-shot latch for key-based shortcuts so key repeat cannot re-trigger them
    /// until the physical key is released.
    private var latchedKeyDowns = Set<UInt32>()

    /// Prevents re-triggering PTT on the same fn press after cancel/end.
    /// Set true when fn press is consumed; reset only when fn is fully released.
    private var modifierConsumed = false
    /// When toggle recording is already active, fn should stop that toggle on release
    /// instead of arming a fresh PTT session.
    private var pendingToggleStopOnModifierRelease = false

    // Double-tap fn detection for mode toggle
    private var lastFnPressTime: Date?
    private var lastFnReleaseTime: Date?
    private var lastFnPressDuration: TimeInterval = .greatestFiniteMagnitude
    /// Actual fn release time, captured before grace timer delay.
    private var pendingGraceReleaseTime: Date?
    private let doubleTapMaxGap: TimeInterval = 0.35
    private let doubleTapMaxHold: TimeInterval = 0.25

    public init(ptt: GlobalShortcut = .defaultPTT, toggle: GlobalShortcut = .defaultToggle) {
        self.pttShortcut = ptt
        self.toggleShortcut = toggle
    }

    /// Start monitoring. Checks Accessibility permission first.
    public func start() {
        stop()

        let trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            #if DEBUG
            print("[GlobalShortcut] Accessibility not granted — prompting user")
            #endif
        }

        // flagsChanged monitors (global + local) for modifier key detection
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handleFlagsChanged(e)
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            self?.handleFlagsChanged(e)
            return e
        }) { monitors.append(m) }

        // CGEvent tap for keyDown/keyUp — allows suppressing shortcut keys (e.g. Space)
        isKeySuppressionAvailable = installEventTap()

        #if DEBUG
        let modeToggleLabel = modeToggleShortcut?.displayString ?? "double-click fn"
        print("[GlobalShortcut] Started — PTT: \(pttShortcut.displayString), Toggle: \(toggleShortcut.displayString), ModeToggle: \(modeToggleLabel), accessible: \(trusted)")
        #endif
    }

    /// Stop all monitoring.
    public func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        removeEventTap()
        isKeySuppressionAvailable = false
        modifierConsumed = false
        safetyTimer?.invalidate()
        safetyTimer = nil
        safetyWarningTimer?.invalidate()
        safetyWarningTimer = nil
        pttEndGraceTimer?.invalidate()
        pttEndGraceTimer = nil
        pendingGraceReleaseTime = nil
        pttActive = false
        currentModifierRawValue = 0
        pendingToggleStopOnModifierRelease = false
        latchedKeyDowns.removeAll()
        // Reset double-tap state so stale timing doesn't carry across stop/start cycles
        lastFnPressTime = nil
        lastFnReleaseTime = nil
        lastFnPressDuration = .greatestFiniteMagnitude
        lastFlagsChangedID = (.max, 0, 0)
    }

    /// Whether PTT is currently active.
    public var isPTTActive: Bool { pttActive }

    // MARK: - CGEvent Tap

    @discardableResult
    private func installEventTap() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: shortcutEventTapCallback,
            userInfo: refcon
        ) {
            eventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            installKeyMonitors()
            return true
        } else {
            #if DEBUG
            print("[GlobalShortcut] CGEvent tap failed — no key suppression available")
            #endif
            return false
        }
    }

    /// NSEvent monitors for keyDown/keyUp — installed only when the event tap is active,
    /// so key-based shortcuts never trigger without safe suppression.
    private func installKeyMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.handleKeyDown(keyCode: UInt32(e.keyCode), flags: e.modifierFlags)
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            self?.handleKeyDown(keyCode: UInt32(e.keyCode), flags: e.modifierFlags)
            return e
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: { [weak self] e in
            self?.handleKeyUp(keyCode: UInt32(e.keyCode))
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { [weak self] e in
            self?.handleKeyUp(keyCode: UInt32(e.keyCode))
            return e
        }) { monitors.append(m) }
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called by the CGEvent tap callback. Returns the event to pass through, or nil to suppress.
    func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it (happens under heavy load)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        // CGEventFlags and NSEvent.ModifierFlags share the same raw values
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))

        switch type {
        case .keyDown:
            let suppress = handleKeyDown(keyCode: keyCode, flags: flags)
            return suppress ? nil : Unmanaged.passUnretained(event)
        case .keyUp:
            let suppress = handleKeyUp(keyCode: keyCode)
            return suppress ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Event Handling

    func handleFlagsChanged(_ event: NSEvent) {
        handleFlagsChanged(keyCode: UInt32(event.keyCode), flags: event.modifierFlags)
    }

    func handleFlagsChanged(keyCode eventKeyCode: UInt32, flags: NSEvent.ModifierFlags) {
        let now = CFAbsoluteTimeGetCurrent()
        let relevantFlags = GlobalShortcut.relevantModifierRawValue(from: flags.rawValue)
        let fnBit = NSEvent.ModifierFlags.function.rawValue
        let hasFn = (flags.rawValue & fnBit) != 0
        logHandler?("[GlobalShortcut] flagsChanged keyCode=\(eventKeyCode) hasFn=\(hasFn) flags=0x\(String(relevantFlags, radix: 16)) prev=0x\(String(currentModifierRawValue, radix: 16)) pttActive=\(pttActive)")
        if eventKeyCode == lastFlagsChangedID.keyCode,
           relevantFlags == lastFlagsChangedID.flags,
           (now - lastFlagsChangedID.time) < 0.02 {
            logHandler?("[GlobalShortcut] DEDUP — skipped duplicate flagsChanged")
            return
        }
        lastFlagsChangedID = (eventKeyCode, relevantFlags, now)
        let previousModifierRawValue = currentModifierRawValue
        currentModifierRawValue = relevantFlags

        if let modeToggleShortcut,
           modeToggleShortcut.isModifierOnly,
           didModifierShortcutBecomePressed(
            modeToggleShortcut,
            previousModifierRawValue: previousModifierRawValue,
            currentModifierRawValue: currentModifierRawValue
           ) {
            delegate?.modeToggleDidTrigger()
            return
        }

        // Modifier-only PTT (e.g. fn alone)
        if pttShortcut.isModifierOnly {
            let modifierPressed = didModifierShortcutBecomePressed(
                pttShortcut,
                previousModifierRawValue: previousModifierRawValue,
                currentModifierRawValue: currentModifierRawValue
            )
            let modifierReleased = didModifierShortcutBecomeReleased(
                pttShortcut,
                previousModifierRawValue: previousModifierRawValue,
                currentModifierRawValue: currentModifierRawValue
            )
            let isFnShortcut = isFunctionModifierShortcut(pttShortcut)
            if modifierPressed || modifierReleased {
                logHandler?("[GlobalShortcut] transition pressed=\(modifierPressed) released=\(modifierReleased) isFn=\(isFnShortcut) pttActive=\(pttActive) consumed=\(modifierConsumed) graceTimer=\(pttEndGraceTimer != nil)")
            }

            if modifierPressed {
                // fn is down — cancel any pending grace release (fn came back)
                if pttEndGraceTimer != nil {
                    pttEndGraceTimer?.invalidate()
                    pttEndGraceTimer = nil
                    // Grace timer was pending — fn came back before it fired.
                    // Record timing from the first press so double-tap detection works,
                    // using the stored release time (set when fn UP was received).
                    if isFnShortcut, let releaseTime = pendingGraceReleaseTime {
                        if let pressTime = lastFnPressTime {
                            lastFnPressDuration = releaseTime.timeIntervalSince(pressTime)
                        }
                        lastFnReleaseTime = releaseTime
                        lastFnPressTime = nil
                        logHandler?("[GlobalShortcut] fn DOWN during grace — dur=\(String(format: "%.3f", lastFnPressDuration)) pttActive=\(pttActive)")
                    }
                    pendingGraceReleaseTime = nil
                    modifierConsumed = false
                    if pttActive {
                        endPTT()
                    }
                }

                if !modifierConsumed && !pttActive {
                    let now = Date()
                    if delegate?.isToggleRecordingActiveForShortcuts() == true {
                        modifierConsumed = true
                        lastFnPressTime = now
                        pendingToggleStopOnModifierRelease = shouldUseFnReleaseToStopActiveToggleShortcut
                        #if DEBUG
                        if pendingToggleStopOnModifierRelease {
                            print("[GlobalShortcut] fn DOWN — toggle-stop armed")
                        } else {
                            print("[GlobalShortcut] fn DOWN — toggle active, waiting for full shortcut")
                        }
                        #endif
                        return
                    }
                    let gap = lastFnReleaseTime.map { now.timeIntervalSince($0) }
                    let gapStr = gap.map { String(format: "%.3f", $0) } ?? "nil"
                    let durStr = String(format: "%.3f", lastFnPressDuration)
                    logHandler?("[GlobalShortcut] fn DOWN — gap=\(gapStr) lastDuration=\(durStr) thresholdGap=\(doubleTapMaxGap) thresholdHold=\(doubleTapMaxHold)")

                    // Double-tap detection: if last fn tap was short and gap is small, toggle mode
                    if modeToggleShortcut == nil,
                       isFnShortcut,
                       let lastRelease = lastFnReleaseTime,
                       now.timeIntervalSince(lastRelease) < doubleTapMaxGap,
                       lastFnPressDuration < doubleTapMaxHold {
                        modifierConsumed = true
                        lastFnReleaseTime = nil  // reset so triple-tap doesn't re-trigger
                        lastFnPressDuration = .greatestFiniteMagnitude  // prevent stale re-trigger
                        logHandler?("[GlobalShortcut] Double-tap fn — mode toggle")
                        delegate?.modeToggleDidTrigger()
                    } else {
                        // Normal modifier press — start PTT
                        modifierConsumed = true
                        if isFnShortcut {
                            lastFnPressTime = now
                        }
                        startPTT()
                    }
                }
            } else if modifierReleased {
                if pendingToggleStopOnModifierRelease {
                    let now = Date()
                    if isFnShortcut, let pressTime = lastFnPressTime {
                        lastFnPressDuration = now.timeIntervalSince(pressTime)
                        #if DEBUG
                        print("[GlobalShortcut] fn UP — stopping toggle after: \(String(format: "%.3f", lastFnPressDuration))s")
                        #endif
                    }
                    if isFnShortcut {
                        lastFnReleaseTime = now
                        lastFnPressTime = nil
                    }
                    modifierConsumed = false
                    pendingToggleStopOnModifierRelease = false
                    delegate?.toggleDidPress()
                    return
                }

                // fn gets spurious flag drops from macOS. Other modifiers can end immediately.
                if isFnShortcut, pttActive && pttEndGraceTimer == nil {
                    let releaseTime = Date()
                    pendingGraceReleaseTime = releaseTime
                    pttEndGraceTimer = Timer.scheduledTimer(withTimeInterval: pttEndGracePeriod, repeats: false) { [weak self] _ in
                        guard let self else { return }
                        self.pttEndGraceTimer = nil
                        self.pendingGraceReleaseTime = nil
                        if let pressTime = self.lastFnPressTime {
                            self.lastFnPressDuration = releaseTime.timeIntervalSince(pressTime)
                        }
                        self.lastFnReleaseTime = releaseTime
                        self.lastFnPressTime = nil
                        self.modifierConsumed = false
                        self.logHandler?("[GlobalShortcut] fn UP (grace confirmed) — held=\(String(format: "%.3f", self.lastFnPressDuration))s pttActive=\(self.pttActive)")
                        if self.pttActive {
                            self.endPTT()
                        }
                    }
                } else if pttActive {
                    // NSEvent global/local monitors can both report fn-up before the grace
                    // timer fires. Ignore duplicate releases so the pending first-tap timing
                    // survives for double-tap mode-toggle detection.
                    if isFnShortcut, pttEndGraceTimer != nil {
                        return
                    }
                    modifierConsumed = false
                    endPTT()
                } else if !pttActive {
                    // Not in PTT — handle release immediately (double-tap timing)
                    let now = Date()
                    if isFnShortcut, let pressTime = lastFnPressTime {
                        lastFnPressDuration = now.timeIntervalSince(pressTime)
                        #if DEBUG
                        print("[GlobalShortcut] fn UP — held for: \(String(format: "%.3f", lastFnPressDuration))s")
                        #endif
                    }
                    if isFnShortcut {
                        lastFnReleaseTime = now
                        lastFnPressTime = nil
                    }
                    modifierConsumed = false
                }
            }
        }

        if toggleShortcut.isModifierOnly,
           didModifierShortcutBecomePressed(
            toggleShortcut,
            previousModifierRawValue: previousModifierRawValue,
            currentModifierRawValue: currentModifierRawValue
           ) {
            pendingToggleStopOnModifierRelease = false
            modifierConsumed = true
            cancelModifierOnlyPTTForToggleOverrideIfNeeded()
            delegate?.toggleDidPress()
            return
        }

        if let micToggleShortcut,
           micToggleShortcut.isModifierOnly,
           didModifierShortcutBecomePressed(
            micToggleShortcut,
            previousModifierRawValue: previousModifierRawValue,
            currentModifierRawValue: currentModifierRawValue
           ) {
            delegate?.micToggleDidTrigger()
            return
        }

        // Non-modifier-only PTT: safety fallback — if modifier portion released, end PTT
        if pttActive && !pttShortcut.isModifierOnly {
            if !matchesModifiers(flags.rawValue, required: pttShortcut.modifiers) {
                #if DEBUG
                print("[GlobalShortcut] Modifier released while key-based PTT active — safety release")
                #endif
                endPTT()
            }
        }
    }

    /// Returns true if the key event should be suppressed (swallowed).
    @discardableResult
    func handleKeyDown(keyCode: UInt32, flags: NSEvent.ModifierFlags) -> Bool {
        // Dedup: skip if the same keyCode was handled within 20ms (CGEvent tap + NSEvent monitor overlap)
        let now = CFAbsoluteTimeGetCurrent()
        if keyCode == lastKeyDownID.keyCode && (now - lastKeyDownID.time) < 0.02 {
            return false
        }
        lastKeyDownID = (keyCode, now)

        if latchedKeyDowns.contains(keyCode) {
            return isShortcutKeyCode(keyCode)
        }

        if let modeToggleShortcut {
            let modeToggleModifierRawValue = effectiveModifierRawValue(for: flags, required: modeToggleShortcut.modifiers)
            if let modeToggleKey = modeToggleShortcut.keyCode,
               keyCode == modeToggleKey,
               matchesModifiers(modeToggleModifierRawValue, required: modeToggleShortcut.modifiers) {
                latchedKeyDowns.insert(keyCode)
                delegate?.modeToggleDidTrigger()
                return true
            }
        }

        // Check toggle shortcut
        let toggleModifierRawValue = effectiveModifierRawValue(for: flags, required: toggleShortcut.modifiers)
        if let toggleKey = toggleShortcut.keyCode,
           keyCode == toggleKey,
           matchesModifiers(toggleModifierRawValue, required: toggleShortcut.modifiers) {
            latchedKeyDowns.insert(keyCode)
            if pendingToggleStopOnModifierRelease {
                pendingToggleStopOnModifierRelease = false
                modifierConsumed = true
                #if DEBUG
                print("[GlobalShortcut] Toggle pressed — stopping active toggle")
                #endif
                delegate?.toggleDidPress()
                return true
            }
            // If modifier-only PTT is active (e.g. fn held then Space pressed),
            // cancel it without transcribing — toggle takes priority
            if pttActive && pttShortcut.isModifierOnly {
                pttActive = false
                safetyTimer?.invalidate()
                safetyTimer = nil
                safetyWarningTimer?.invalidate()
                safetyWarningTimer = nil
                pttEndGraceTimer?.invalidate()
                pttEndGraceTimer = nil
                #if DEBUG
                print("[GlobalShortcut] PTT cancelled — toggle takes priority")
                #endif
                delegate?.pttDidCancel()
            }
            guard !pttActive else { return true }
            #if DEBUG
            print("[GlobalShortcut] Toggle pressed")
            #endif
            delegate?.toggleDidPress()
            return true  // suppress key from reaching focused app
        }

        if let micToggleShortcut {
            let micModifierRawValue = effectiveModifierRawValue(for: flags, required: micToggleShortcut.modifiers)
            if let micKey = micToggleShortcut.keyCode,
               keyCode == micKey,
               matchesModifiers(micModifierRawValue, required: micToggleShortcut.modifiers) {
                latchedKeyDowns.insert(keyCode)
                delegate?.micToggleDidTrigger()
                return true
            }
        }

        // Check key-based PTT press
        let pttModifierRawValue = effectiveModifierRawValue(for: flags, required: pttShortcut.modifiers)
        if let pttKey = pttShortcut.keyCode,
           keyCode == pttKey,
           matchesModifiers(pttModifierRawValue, required: pttShortcut.modifiers),
           !pttActive {
            latchedKeyDowns.insert(keyCode)
            startPTT()
            return true  // suppress
        }

        return false  // pass through
    }

    /// Returns true if the key event should be suppressed.
    @discardableResult
    func handleKeyUp(keyCode: UInt32) -> Bool {
        latchedKeyDowns.remove(keyCode)

        let now = CFAbsoluteTimeGetCurrent()
        if keyCode == lastKeyUpID.keyCode && (now - lastKeyUpID.time) < 0.02 {
            return false
        }
        lastKeyUpID = (keyCode, now)

        if let pttKey = pttShortcut.keyCode,
           keyCode == pttKey,
           pttActive {
            endPTT()
            return true  // suppress
        }
        return false
    }

    private func isShortcutKeyCode(_ keyCode: UInt32) -> Bool {
        pttShortcut.keyCode == keyCode ||
        toggleShortcut.keyCode == keyCode ||
        micToggleShortcut?.keyCode == keyCode ||
        modeToggleShortcut?.keyCode == keyCode
    }

    // MARK: - PTT Lifecycle

    private func startPTT() {
        pttActive = true
        #if DEBUG
        print("[GlobalShortcut] PTT started")
        #endif
        delegate?.pttDidPress()
        startSafetyTimer()
    }

    private func endPTT() {
        guard pttActive else { return }
        pttActive = false
        safetyTimer?.invalidate()
        safetyTimer = nil
        safetyWarningTimer?.invalidate()
        safetyWarningTimer = nil
        pttEndGraceTimer?.invalidate()
        pttEndGraceTimer = nil
        #if DEBUG
        print("[GlobalShortcut] PTT ended")
        #endif
        delegate?.pttDidRelease()
    }

    private var shouldUseFnReleaseToStopActiveToggleShortcut: Bool {
        guard toggleShortcut.normalizedModifiers.contains(.function) else { return false }
        if toggleShortcut.isModifierOnly {
            return toggleShortcut == .defaultPTT
        }
        return true
    }

    private func cancelModifierOnlyPTTForToggleOverrideIfNeeded() {
        guard pttActive, pttShortcut.isModifierOnly else { return }
        pttActive = false
        safetyTimer?.invalidate()
        safetyTimer = nil
        safetyWarningTimer?.invalidate()
        safetyWarningTimer = nil
        pttEndGraceTimer?.invalidate()
        pttEndGraceTimer = nil
        #if DEBUG
        print("[GlobalShortcut] PTT cancelled — toggle takes priority")
        #endif
        delegate?.pttDidCancel()
    }

    private func startSafetyTimer() {
        safetyTimer?.invalidate()
        safetyWarningTimer?.invalidate()

        safetyWarningTimer = Timer.scheduledTimer(withTimeInterval: safetyWarningAt, repeats: false) { [weak self] _ in
            guard let self = self, self.pttActive else { return }
            let remaining = Int(self.safetyTimeout - self.safetyWarningAt)
            #if DEBUG
            print("[GlobalShortcut] PTT safety warning — \(remaining)s remaining")
            #endif
            self.delegate?.pttDidWarnTimeout(remainingSeconds: remaining)
        }

        safetyTimer = Timer.scheduledTimer(withTimeInterval: safetyTimeout, repeats: false) { [weak self] _ in
            guard let self = self, self.pttActive else { return }
            #if DEBUG
            print("[GlobalShortcut] Safety timeout (\(self.safetyTimeout)s) — auto-ending PTT")
            #endif
            self.endPTT()
        }
    }

    // MARK: - Helpers

    static func mergedModifierRawValue(eventRawValue: UInt, currentRawValue: UInt, requiredRawValue: UInt) -> UInt {
        let eventRelevant = GlobalShortcut.relevantModifierRawValue(from: eventRawValue)
        let currentRelevant = GlobalShortcut.relevantModifierRawValue(from: currentRawValue)
        let requiredRelevant = GlobalShortcut.relevantModifierRawValue(from: requiredRawValue)

        var merged = eventRelevant

        let eventNormalized = GlobalShortcut.normalizedModifierFlags(fromRaw: eventRelevant)
        let requiredNormalized = GlobalShortcut.normalizedModifierFlags(fromRaw: requiredRelevant)
        let missingNormalized = requiredNormalized.subtracting(eventNormalized)
        merged |= currentRelevant & missingNormalized.rawValue

        let requiredDeviceBits = GlobalShortcut.deviceDependentModifierRawValue(from: requiredRelevant)
        if requiredDeviceBits != 0 {
            merged |= currentRelevant & requiredDeviceBits
        }

        return GlobalShortcut.relevantModifierRawValue(from: merged)
    }

    private func effectiveModifierRawValue(for flags: NSEvent.ModifierFlags, required: UInt) -> UInt {
        Self.mergedModifierRawValue(
            eventRawValue: flags.rawValue,
            currentRawValue: currentModifierRawValue,
            requiredRawValue: required
        )
    }

    private func isFunctionModifierShortcut(_ shortcut: GlobalShortcut) -> Bool {
        guard shortcut.keyCode == nil else { return false }
        if shortcut.modifierKeyCode == 63 { return true }
        // V1 saved fn shortcut without modifierKeyCode — check flags directly.
        // Only match fn-alone (not fn+Command combos) so the grace timer and
        // double-tap detection only apply to pure fn PTT.
        let normalized = GlobalShortcut.normalizedModifierFlags(fromRaw: shortcut.modifiers)
        return normalized == .function
    }

    private func didModifierShortcutBecomePressed(
        _ shortcut: GlobalShortcut,
        previousModifierRawValue: UInt,
        currentModifierRawValue: UInt
    ) -> Bool {
        guard shortcut.isModifierOnly else { return false }
        return !matchesModifiers(previousModifierRawValue, required: shortcut.modifiers) &&
            matchesModifiers(currentModifierRawValue, required: shortcut.modifiers)
    }

    private func didModifierShortcutBecomeReleased(
        _ shortcut: GlobalShortcut,
        previousModifierRawValue: UInt,
        currentModifierRawValue: UInt
    ) -> Bool {
        guard shortcut.isModifierOnly else { return false }
        return matchesModifiers(previousModifierRawValue, required: shortcut.modifiers) &&
            !matchesModifiers(currentModifierRawValue, required: shortcut.modifiers)
    }

    private func matchesModifiers(_ eventModifierRawValue: UInt, required: UInt) -> Bool {
        GlobalShortcut.modifiersMatch(eventModifierRawValue, required: required)
    }
}
