import XCTest
import AppKit
import HotkeyModule
@testable import App

final class FnKeyToggleTests: XCTestCase {
    private func defaults() -> ShortcutSettingsState {
        ShortcutSettingsState(pttShortcut: .defaultPTT, toggleShortcut: .defaultToggle,
                              micToggleShortcut: .defaultMicToggle, modeToggleShortcut: nil)
    }

    func testDefaultsUseFn() {
        XCTAssertTrue(defaults().usesFnKey)
    }

    func testStopUsingFnMovesEveryFnShortcut() {
        var state = defaults()
        XCTAssertTrue(state.stopUsingFnKey())
        XCTAssertFalse(state.usesFnKey)
        XCTAssertEqual(state.pttShortcut, ShortcutSettingsState.fnFreePTT)
        XCTAssertEqual(state.toggleShortcut, ShortcutSettingsState.fnFreeToggle)
        XCTAssertEqual(state.modeToggleShortcut, ShortcutSettingsState.fnFreeModeToggle)
        XCTAssertNil(state.shortcutError)
    }

    func testStopUsingFnKeepsCustomNonFnShortcuts() {
        let custom = GlobalShortcut(keyCode: 3, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue) // ⌥⌘F
        var state = defaults()
        state.pttShortcut = custom
        XCTAssertTrue(state.stopUsingFnKey())
        XCTAssertEqual(state.pttShortcut, custom)
    }

    func testClashLeavesStateUntouchedAndExplains() {
        var state = defaults()
        state.micToggleShortcut = StoredShortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, modifierKeyCode: nil)
        let before = state
        XCTAssertFalse(state.stopUsingFnKey())
        XCTAssertEqual(state.pttShortcut, before.pttShortcut)
        XCTAssertNotNil(state.shortcutError)
    }

    func testTurningFnBackOnRestoresFnDefaults() {
        var state = defaults()
        _ = state.stopUsingFnKey()
        state.useFnKeyDefaults()
        XCTAssertEqual(state.pttShortcut, .defaultPTT)
        XCTAssertEqual(state.toggleShortcut, .defaultToggle)
        XCTAssertNil(state.modeToggleShortcut)
        XCTAssertTrue(state.usesFnKey)
    }
}
