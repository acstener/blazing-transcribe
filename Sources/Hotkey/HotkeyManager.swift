import AppKit
import HotKey
import Carbon

public protocol HotkeyDelegate: AnyObject {
    func hotkeyDidTrigger()
    func hotkeyDidRelease()
    func micToggleDidTrigger()
    func llmCleanupToggleDidTrigger()
}

/// Default no-ops so existing conformances don't break.
public extension HotkeyDelegate {
    func hotkeyDidRelease() {}
    func micToggleDidTrigger() {}
    func llmCleanupToggleDidTrigger() {}
}

/// Manages global hotkey registration using Carbon RegisterEventHotKey (via HotKey library).
/// No Accessibility permission needed.
public final class HotkeyManager {
    public weak var delegate: HotkeyDelegate?

    private var hotKey: HotKey?
    private var micToggleKey: HotKey?
    private var llmCleanupToggleKey: HotKey?

    /// When true, keyUp events are also delivered to the delegate.
    public var keyUpEnabled: Bool = false

    public init() {}

    /// Register hotkeys with configurable key codes and modifiers.
    /// Pass nil for actionKeyCode to skip action hotkey registration.
    public func register(
        actionKeyCode: UInt32? = nil, actionModifiers: NSEvent.ModifierFlags = [],
        micKeyCode: UInt32? = nil, micModifiers: NSEvent.ModifierFlags = [],
        llmCleanupToggleKeyCode: UInt32? = nil, llmCleanupToggleModifiers: NSEvent.ModifierFlags = []
    ) {
        if let actionKeyCode = actionKeyCode, let key = Key(carbonKeyCode: actionKeyCode) {
            hotKey = HotKey(key: key, modifiers: actionModifiers)
            hotKey?.keyDownHandler = { [weak self] in
                #if DEBUG
                print("[Hotkey] Key down!")
                #endif
                self?.delegate?.hotkeyDidTrigger()
            }
            hotKey?.keyUpHandler = { [weak self] in
                guard let self = self, self.keyUpEnabled else { return }
                #if DEBUG
                print("[Hotkey] Key up!")
                #endif
                self.delegate?.hotkeyDidRelease()
            }
        }

        if let micKeyCode, let key = Key(carbonKeyCode: micKeyCode) {
            micToggleKey = HotKey(key: key, modifiers: micModifiers)
            micToggleKey?.keyDownHandler = { [weak self] in
                #if DEBUG
                print("[Hotkey] Mic toggle!")
                #endif
                self?.delegate?.micToggleDidTrigger()
            }
        }

        if let llmCleanupToggleKeyCode, let key = Key(carbonKeyCode: llmCleanupToggleKeyCode) {
            llmCleanupToggleKey = HotKey(key: key, modifiers: llmCleanupToggleModifiers)
            llmCleanupToggleKey?.keyDownHandler = { [weak self] in
                #if DEBUG
                print("[Hotkey] LLM cleanup toggle!")
                #endif
                self?.delegate?.llmCleanupToggleDidTrigger()
            }
        }

        #if DEBUG
        print("[Hotkey] Registered hotkeys (action: \(actionKeyCode != nil ? "yes" : "none"))")
        #endif
    }

    /// Unregister all hotkeys.
    public func unregister() {
        hotKey = nil
        micToggleKey = nil
        llmCleanupToggleKey = nil
    }
}
