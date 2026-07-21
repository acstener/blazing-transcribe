import AppKit
import HotkeyModule

struct StoredShortcut: Codable, Equatable {
    let keyCode: UInt32?
    let modifiers: UInt  // NSEvent.ModifierFlags.rawValue + device-dependent modifier bits
    let modifierKeyCode: UInt32?

    var nsModifiers: NSEvent.ModifierFlags {
        GlobalShortcut.normalizedModifierFlags(fromRaw: modifiers)
    }

    var displayString: String {
        asGlobalShortcut.displayString
    }

    static let defaultMicToggle = StoredShortcut(
        keyCode: 0x2E, // M
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
        modifierKeyCode: nil
    )
    static let defaultPushToTalk = StoredShortcut(
        keyCode: nil,
        modifiers: NSEvent.ModifierFlags([.function]).rawValue,
        modifierKeyCode: 63
    )
}

final class ShortcutConfig {
    static let shared = ShortcutConfig()

    private let defaults = UserDefaults.standard
    private let actionKey = "shortcut.action"
    private let micKey = "shortcut.micToggle"
    private let recordingModeKey = "recordingMode"
    private let pttKey = "shortcut.ptt"
    private let toggleKey = "shortcut.toggle"
    private let modeToggleKey = "shortcut.modeToggle"

    var actionShortcut: StoredShortcut? {
        get { load(actionKey) }
        set {
            if let newValue = newValue {
                save(actionKey, newValue)
            } else {
                defaults.removeObject(forKey: actionKey)
            }
        }
    }

    var micToggleShortcut: StoredShortcut {
        get { load(micKey) ?? .defaultMicToggle }
        set { save(micKey, newValue) }
    }

    var recordingMode: RecordingMode {
        get {
            guard let raw = defaults.string(forKey: recordingModeKey) else { return .alwaysOn }
            return RecordingMode(rawValue: raw) ?? .alwaysOn
        }
        set {
            defaults.set(newValue.rawValue, forKey: recordingModeKey)
        }
    }

    var pttShortcut: GlobalShortcut {
        get { loadGlobal(pttKey) ?? .defaultPTT }
        set { saveGlobal(pttKey, newValue) }
    }

    var toggleShortcut: GlobalShortcut {
        get { loadGlobal(toggleKey) ?? .defaultToggle }
        set { saveGlobal(toggleKey, newValue) }
    }

    /// Temporarily disabled: mode switching always uses the built-in double-click fn gesture.
    var modeToggleShortcut: GlobalShortcut? {
        get { nil }
        set { defaults.removeObject(forKey: modeToggleKey) }
    }

    func clearLegacyModeToggleShortcut() {
        defaults.removeObject(forKey: modeToggleKey)
    }

    private func load(_ key: String) -> StoredShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
    }

    private func save(_ key: String, _ shortcut: StoredShortcut) {
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadGlobal(_ key: String) -> GlobalShortcut? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GlobalShortcut.self, from: data)
    }

    private func saveGlobal(_ key: String, _ shortcut: GlobalShortcut) {
        if let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        }
    }
}

extension StoredShortcut {
    var asGlobalShortcut: GlobalShortcut {
        GlobalShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            modifierKeyCode: modifierKeyCode
        )
    }
}
