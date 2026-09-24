import AppKit
import HotkeyModule

/// What macOS does when the fn / Globe key is pressed
/// (System Settings → Keyboard → "Press 🌐 key to").
///
/// Stored as `AppleFnUsageType` in the `com.apple.HIToolbox` domain:
/// 0 = Do Nothing, 1 = Change Input Source, 2 = Show Emoji & Symbols, 3 = Start Dictation.
enum FnKeySystemAction: Equatable {
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    /// Key absent: the user never changed it, so macOS uses its factory default,
    /// which on Globe-key Macs is an action (Emoji & Symbols or Change Input Source).
    case systemDefault
    case unknown(Int)

    init(rawUsageType: Int?) {
        switch rawUsageType {
        case .none: self = .systemDefault
        case .some(0): self = .doNothing
        case .some(1): self = .changeInputSource
        case .some(2): self = .showEmojiAndSymbols
        case .some(3): self = .startDictation
        case .some(let other): self = .unknown(other)
        }
    }

    /// Whether pressing fn also triggers a system action that would fight an fn shortcut.
    var conflictsWithFnShortcut: Bool {
        switch self {
        case .doNothing: return false
        case .changeInputSource, .showEmojiAndSymbols, .startDictation, .systemDefault: return true
        case .unknown: return false
        }
    }

    /// Short label for UI copy ("fn is set to …").
    var displayName: String {
        switch self {
        case .doNothing: return "Do Nothing"
        case .changeInputSource: return "Change Input Source"
        case .showEmojiAndSymbols: return "Show Emoji & Symbols"
        case .startDictation: return "Start Dictation"
        case .systemDefault: return "the system default"
        case .unknown: return "an unknown action"
        }
    }

    /// Analytics-safe label.
    var analyticsLabel: String {
        switch self {
        case .doNothing: return "doNothing"
        case .changeInputSource: return "inputSource"
        case .showEmojiAndSymbols: return "emoji"
        case .startDictation: return "dictation"
        case .systemDefault: return "systemDefault"
        case .unknown(let value): return "unknown\(value)"
        }
    }
}

enum FnKeyConflictDetector {
    static let domain = "com.apple.HIToolbox" as CFString
    static let key = "AppleFnUsageType" as CFString

    /// Reads the current system fn/Globe action. Cheap; safe to call on app activation.
    static func currentAction() -> FnKeySystemAction {
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue(key, domain)
        return FnKeySystemAction(rawUsageType: (value as? NSNumber)?.intValue)
    }

    /// Whether a shortcut is the fn / Globe key on its own. (fn combined with
    /// another key doesn't trigger the system Globe action.)
    static func shortcutUsesFn(_ shortcut: GlobalShortcut) -> Bool {
        guard shortcut.keyCode == nil else { return false }
        return shortcut.modifierKeyCode == 63 || shortcut.nsModifiers.contains(.function)
    }

    /// True when the push-to-talk shortcut uses fn and macOS also acts on fn.
    static func isConflicting(action: FnKeySystemAction, pttShortcut: GlobalShortcut) -> Bool {
        shortcutUsesFn(pttShortcut) && action.conflictsWithFnShortcut
    }
}
