import AppKit
import HotkeyModule

struct ShortcutSettingsState {
    var pttShortcut: GlobalShortcut
    var toggleShortcut: GlobalShortcut
    var micToggleShortcut: StoredShortcut
    /// `nil` means use the default double-click fn gesture.
    var modeToggleShortcut: GlobalShortcut?
    var shortcutError: String?

    init(
        pttShortcut: GlobalShortcut = ShortcutConfig.shared.pttShortcut,
        toggleShortcut: GlobalShortcut = ShortcutConfig.shared.toggleShortcut,
        micToggleShortcut: StoredShortcut = ShortcutConfig.shared.micToggleShortcut,
        modeToggleShortcut: GlobalShortcut? = ShortcutConfig.shared.modeToggleShortcut,
        shortcutError: String? = nil
    ) {
        self.pttShortcut = pttShortcut
        self.toggleShortcut = toggleShortcut
        self.micToggleShortcut = micToggleShortcut
        self.modeToggleShortcut = modeToggleShortcut
        self.shortcutError = shortcutError
    }

    static func defaultModeToggleLabel() -> String {
        "Double-click fn"
    }

    static func modeToggleLabel(for shortcut: GlobalShortcut?) -> String {
        shortcut?.displayString ?? defaultModeToggleLabel()
    }

    mutating func updatePTT(keyCode: UInt32?, modifiers: UInt, modifierKeyCode: UInt32?) -> GlobalShortcut? {
        let candidate = GlobalShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            modifierKeyCode: modifierKeyCode
        )

        guard validatePTTShortcut(candidate) else { return nil }
        guard !candidate.conflicts(with: toggleShortcut) else {
            shortcutError = "Push-to-Talk and Toggle Recording cannot use the same shortcut."
            return nil
        }
        guard !candidate.conflicts(with: micToggleShortcut.asGlobalShortcut) else {
            shortcutError = "Push-to-Talk and Toggle Mic cannot use the same shortcut."
            return nil
        }
        if let modeToggleShortcut,
           candidate.conflicts(with: modeToggleShortcut) {
            shortcutError = "Push-to-Talk and Switch Mode cannot use the same shortcut."
            return nil
        }

        shortcutError = nil
        pttShortcut = candidate
        return candidate
    }

    mutating func updateToggleRecording(keyCode: UInt32?, modifiers: UInt, modifierKeyCode: UInt32?) -> GlobalShortcut? {
        let candidate = GlobalShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            modifierKeyCode: modifierKeyCode
        )

        guard validateShortcut(candidate, label: "Toggle Recording") else { return nil }
        guard !candidate.conflicts(with: pttShortcut) else {
            shortcutError = "Toggle Recording and Push-to-Talk cannot use the same shortcut."
            return nil
        }
        guard !candidate.conflicts(with: micToggleShortcut.asGlobalShortcut) else {
            shortcutError = "Toggle Recording and Toggle Mic cannot use the same shortcut."
            return nil
        }
        if let modeToggleShortcut,
           candidate.conflicts(with: modeToggleShortcut) {
            shortcutError = "Toggle Recording and Switch Mode cannot use the same shortcut."
            return nil
        }

        shortcutError = nil
        toggleShortcut = candidate
        return candidate
    }

    mutating func updateMicToggle(keyCode: UInt32?, modifiers: UInt, modifierKeyCode: UInt32?) -> StoredShortcut? {
        let candidate = StoredShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            modifierKeyCode: modifierKeyCode
        )
        guard validateShortcut(candidate.asGlobalShortcut, label: "Toggle Mic") else { return nil }

        let candidateGlobal = candidate.asGlobalShortcut
        guard !candidateGlobal.conflicts(with: pttShortcut) else {
            shortcutError = "Toggle Mic and Push-to-Talk cannot use the same shortcut."
            return nil
        }
        guard !candidateGlobal.conflicts(with: toggleShortcut) else {
            shortcutError = "Toggle Mic and Toggle Recording cannot use the same shortcut."
            return nil
        }
        if let modeToggleShortcut,
           candidateGlobal.conflicts(with: modeToggleShortcut) {
            shortcutError = "Toggle Mic and Switch Mode cannot use the same shortcut."
            return nil
        }

        shortcutError = nil
        micToggleShortcut = candidate
        return candidate
    }

    mutating func updateModeToggle(keyCode: UInt32?, modifiers: UInt, modifierKeyCode: UInt32?) -> GlobalShortcut? {
        let candidate = GlobalShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            modifierKeyCode: modifierKeyCode
        )

        guard validateShortcut(candidate, label: "Switch Mode") else { return nil }
        guard !candidate.conflicts(with: pttShortcut) else {
            shortcutError = "Switch Mode and Push-to-Talk cannot use the same shortcut."
            return nil
        }
        guard !candidate.conflicts(with: toggleShortcut) else {
            shortcutError = "Switch Mode and Toggle Recording cannot use the same shortcut."
            return nil
        }
        guard !candidate.conflicts(with: micToggleShortcut.asGlobalShortcut) else {
            shortcutError = "Switch Mode and Toggle Mic cannot use the same shortcut."
            return nil
        }

        shortcutError = nil
        modeToggleShortcut = candidate
        return candidate
    }

    mutating func resetPTT() -> GlobalShortcut {
        shortcutError = nil
        pttShortcut = .defaultPTT
        return .defaultPTT
    }

    mutating func resetToggleRecording() -> GlobalShortcut {
        shortcutError = nil
        toggleShortcut = .defaultToggle
        return .defaultToggle
    }

    mutating func resetMicToggle() -> StoredShortcut {
        shortcutError = nil
        micToggleShortcut = .defaultMicToggle
        return .defaultMicToggle
    }

    mutating func resetModeToggle() -> GlobalShortcut? {
        shortcutError = nil
        modeToggleShortcut = nil
        return nil
    }

    private mutating func validatePTTShortcut(_ shortcut: GlobalShortcut) -> Bool {
        validateShortcut(shortcut, label: "Push-to-Talk")
    }

    private mutating func validateShortcut(_ shortcut: GlobalShortcut, label: String) -> Bool {
        if shortcut.isModifierOnly {
            guard !shortcut.normalizedModifiers.isEmpty else {
                shortcutError = "\(label) must include at least one modifier key."
                return false
            }

            if let modifierKeyCode = shortcut.modifierKeyCode {
                guard let modifierFlag = GlobalShortcut.modifierFlag(forModifierKeyCode: modifierKeyCode),
                      shortcut.normalizedModifiers == modifierFlag else {
                    shortcutError = "\(label) side-specific modifier shortcuts must use a single modifier key."
                    return false
                }
            }
            return true
        }

        guard shortcut.keyCode != nil else {
            shortcutError = "\(label) must include a key or at least one modifier key."
            return false
        }
        return true
    }
}
