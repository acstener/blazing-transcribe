import XCTest
import AppKit
@testable import App
@testable import HotkeyModule

final class ShortcutSettingsStateTests: XCTestCase {
    func testPTTShortcutUpdateFeedsBackendMonitor() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let updated = state.updatePTT(
            keyCode: 0x0F,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            modifierKeyCode: nil
        )

        XCTAssertEqual(updated?.displayString, "⇧ ⌘ R")
        XCTAssertNil(state.shortcutError)

        let monitor = GlobalShortcutMonitor(ptt: state.pttShortcut, toggle: state.toggleShortcut)
        let delegate = ShortcutStateMonitorDelegateSpy()
        monitor.delegate = delegate

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: [.command, .shift]))
        XCTAssertEqual(delegate.pttPressCount, 1)

        advancePastKeyDedupWindow()

        XCTAssertTrue(monitor.handleKeyUp(keyCode: 0x0F))
        XCTAssertEqual(delegate.pttReleaseCount, 1)
    }

    func testToggleRecordingShortcutUpdateFeedsBackendMonitor() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let updated = state.updateToggleRecording(
            keyCode: 0x0F,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            modifierKeyCode: nil
        )

        XCTAssertEqual(updated?.displayString, "⇧ ⌘ R")
        XCTAssertNil(state.shortcutError)

        let monitor = GlobalShortcutMonitor(ptt: state.pttShortcut, toggle: state.toggleShortcut)
        let delegate = ShortcutStateMonitorDelegateSpy()
        monitor.delegate = delegate

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: [.command, .shift]))
        XCTAssertEqual(delegate.toggleCount, 1)
    }

    func testFnBasedToggleRecordingShortcutUpdateFeedsBackendMonitor() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let updated = state.updateToggleRecording(
            keyCode: 0x0F,
            modifiers: NSEvent.ModifierFlags.function.rawValue,
            modifierKeyCode: nil
        )

        XCTAssertEqual(updated?.displayString, "fn R")
        XCTAssertNil(state.shortcutError)

        let monitor = GlobalShortcutMonitor(ptt: state.pttShortcut, toggle: state.toggleShortcut)
        let delegate = ShortcutStateMonitorDelegateSpy()
        monitor.delegate = delegate

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])

        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: []))
        XCTAssertEqual(delegate.pttCancelCount, 1)
        XCTAssertEqual(delegate.toggleCount, 1)
    }

    func testModifierOnlyToggleRecordingShortcutWithFnAndLeftCommandFeedsBackendMonitor() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let rawValue = NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000008
        let updated = state.updateToggleRecording(
            keyCode: nil,
            modifiers: rawValue,
            modifierKeyCode: nil
        )

        XCTAssertEqual(updated?.displayString, "L⌘ fn")
        XCTAssertNil(state.shortcutError)

        let monitor = GlobalShortcutMonitor(ptt: state.pttShortcut, toggle: state.toggleShortcut)
        let delegate = ShortcutStateMonitorDelegateSpy()
        monitor.delegate = delegate

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertEqual(delegate.toggleCount, 0)

        monitor.handleFlagsChanged(
            keyCode: 55,
            flags: NSEvent.ModifierFlags(rawValue: rawValue)
        )
        XCTAssertEqual(delegate.toggleCount, 1)
    }

    func testModifierOnlyPTTShortcutWithFnAndLeftCommandFeedsBackendMonitor() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let rawValue = NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000008
        let updated = state.updatePTT(
            keyCode: nil,
            modifiers: rawValue,
            modifierKeyCode: nil
        )

        XCTAssertEqual(updated?.displayString, "L⌘ fn")
        XCTAssertNil(state.shortcutError)

        let monitor = GlobalShortcutMonitor(ptt: state.pttShortcut, toggle: state.toggleShortcut)
        let delegate = ShortcutStateMonitorDelegateSpy()
        monitor.delegate = delegate

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertEqual(delegate.pttPressCount, 0)

        monitor.handleFlagsChanged(
            keyCode: 55,
            flags: NSEvent.ModifierFlags(rawValue: rawValue)
        )
        XCTAssertEqual(delegate.pttPressCount, 1)

        monitor.handleFlagsChanged(keyCode: 55, flags: [.function])
        XCTAssertEqual(delegate.pttReleaseCount, 1)
    }

    func testMicToggleShortcutUpdateFeedsBackendMonitor() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let updated = state.updateMicToggle(
            keyCode: 0x01,
            modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue,
            modifierKeyCode: nil
        )

        XCTAssertEqual(updated?.displayString, "⌥ ⌘ S")
        XCTAssertNil(state.shortcutError)

        let monitor = GlobalShortcutMonitor(ptt: state.pttShortcut, toggle: state.toggleShortcut)
        let delegate = ShortcutStateMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.micToggleShortcut = state.micToggleShortcut.asGlobalShortcut

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x01, flags: [.command, .option]))
        XCTAssertEqual(delegate.micToggleCount, 1)
    }

    func testModeToggleShortcutUpdateFeedsBackendMonitor() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let updated = state.updateModeToggle(
            keyCode: 0x28,
            modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue,
            modifierKeyCode: nil
        )

        XCTAssertEqual(updated?.displayString, "⌥ ⌘ K")
        XCTAssertEqual(ShortcutSettingsState.modeToggleLabel(for: state.modeToggleShortcut), "⌥ ⌘ K")
        XCTAssertNil(state.shortcutError)

        let monitor = GlobalShortcutMonitor(ptt: state.pttShortcut, toggle: state.toggleShortcut)
        let delegate = ShortcutStateMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.modeToggleShortcut = state.modeToggleShortcut

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x28, flags: [.command, .option]))
        XCTAssertEqual(delegate.modeToggleCount, 1)
    }

    func testResetModeToggleFallsBackToDoubleTapFnLabel() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: .defaultToggle,
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: GlobalShortcut(
                keyCode: 0x28,
                modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
            )
        )

        let resetValue = state.resetModeToggle()

        XCTAssertNil(resetValue)
        XCTAssertNil(state.modeToggleShortcut)
        XCTAssertEqual(ShortcutSettingsState.modeToggleLabel(for: state.modeToggleShortcut), "Double-click fn")
    }

    func testModeToggleRejectsConflictsWithToggleRecording() {
        var state = ShortcutSettingsState(
            pttShortcut: .defaultPTT,
            toggleShortcut: GlobalShortcut(
                keyCode: 0x28,
                modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
            ),
            micToggleShortcut: .defaultMicToggle,
            modeToggleShortcut: nil
        )

        let updated = state.updateModeToggle(
            keyCode: 0x28,
            modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue,
            modifierKeyCode: nil
        )

        XCTAssertNil(updated)
        XCTAssertEqual(state.shortcutError, "Switch Mode and Toggle Recording cannot use the same shortcut.")
    }

    private func advancePastKeyDedupWindow() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}

private final class ShortcutStateMonitorDelegateSpy: GlobalShortcutDelegate {
    var pttPressCount = 0
    var pttReleaseCount = 0
    var pttCancelCount = 0
    var toggleCount = 0
    var micToggleCount = 0
    var modeToggleCount = 0

    func pttDidPress() { pttPressCount += 1 }
    func pttDidRelease() { pttReleaseCount += 1 }
    func pttDidCancel() { pttCancelCount += 1 }
    func toggleDidPress() { toggleCount += 1 }
    func micToggleDidTrigger() { micToggleCount += 1 }
    func modeToggleDidTrigger() { modeToggleCount += 1 }
}
