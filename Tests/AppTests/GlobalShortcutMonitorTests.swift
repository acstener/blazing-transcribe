import XCTest
@testable import HotkeyModule

final class GlobalShortcutMonitorTests: XCTestCase {
    func testDefaultFnSpaceTriggersToggleRecording() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertEqual(delegate.pttPressCount, 1)

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x31, flags: []))
        XCTAssertEqual(delegate.pttCancelCount, 1)
        XCTAssertEqual(delegate.toggleCount, 1)
    }

    func testDefaultFnStopsActiveToggleRecording() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x31, flags: []))
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        XCTAssertTrue(delegate.isToggleRecordingActive)

        advancePastKeyDedupWindow()

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])

        XCTAssertEqual(delegate.toggleCount, 2)
        XCTAssertFalse(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertEqual(delegate.pttCancelCount, 1)
    }

    func testCustomToggleShortcutStopsWithSameShortcut() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.toggleShortcut = GlobalShortcut(
            keyCode: 0x0F,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: [.command, .shift]))
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 1)

        XCTAssertFalse(monitor.handleKeyUp(keyCode: 0x0F))
        advancePastKeyDedupWindow()

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: [.command, .shift]))
        XCTAssertFalse(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 2)
    }

    func testFnBasedToggleShortcutStopsWithSameShortcut() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.toggleShortcut = GlobalShortcut(
            keyCode: 0x0F,
            modifiers: NSEvent.ModifierFlags.function.rawValue
        )

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: []))
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertEqual(delegate.pttCancelCount, 1)
        XCTAssertEqual(delegate.toggleCount, 1)

        advancePastKeyDedupWindow()

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: []))
        monitor.handleFlagsChanged(keyCode: 63, flags: [])

        XCTAssertFalse(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 2)
        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertEqual(delegate.pttCancelCount, 1)
    }

    func testCustomModifierOnlyFnCommandToggleCancelsPTTAndStartsToggle() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        let rawValue = NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000008
        monitor.toggleShortcut = GlobalShortcut(
            keyCode: nil,
            modifiers: rawValue
        )

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertEqual(delegate.pttPressCount, 1)

        monitor.handleFlagsChanged(
            keyCode: 55,
            flags: NSEvent.ModifierFlags(rawValue: rawValue)
        )

        XCTAssertEqual(delegate.pttCancelCount, 1)
        XCTAssertEqual(delegate.toggleCount, 1)
        XCTAssertTrue(delegate.isToggleRecordingActive)
    }

    func testCustomModifierOnlyFnCommandToggleStopsWithSameShortcutNotFnAlone() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        let rawValue = NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000008
        monitor.toggleShortcut = GlobalShortcut(
            keyCode: nil,
            modifiers: rawValue
        )

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(
            keyCode: 55,
            flags: NSEvent.ModifierFlags(rawValue: rawValue)
        )
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 1)

        monitor.handleFlagsChanged(keyCode: 55, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 1)

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(
            keyCode: 55,
            flags: NSEvent.ModifierFlags(rawValue: rawValue)
        )
        XCTAssertFalse(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 2)
    }

    func testDefaultFnSpaceRepeatDoesNotDoubleToggleBeforeKeyUp() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x31, flags: []))
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 1)
        XCTAssertEqual(delegate.pttCancelCount, 1)

        advancePastKeyDedupWindow()

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x31, flags: []))
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 1)

        XCTAssertFalse(monitor.handleKeyUp(keyCode: 0x31))
        advancePastKeyDedupWindow()

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x31, flags: []))
        XCTAssertFalse(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 2)
    }

    func testCustomToggleRepeatDoesNotDoubleToggleBeforeKeyUp() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.toggleShortcut = GlobalShortcut(
            keyCode: 0x0F,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: [.command, .shift]))
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 1)

        advancePastKeyDedupWindow()

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: [.command, .shift]))
        XCTAssertTrue(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 1)

        XCTAssertFalse(monitor.handleKeyUp(keyCode: 0x0F))
        advancePastKeyDedupWindow()

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x0F, flags: [.command, .shift]))
        XCTAssertFalse(delegate.isToggleRecordingActive)
        XCTAssertEqual(delegate.toggleCount, 2)
    }

    func testCustomMicToggleShortcutTriggersDelegate() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.micToggleShortcut = GlobalShortcut(
            keyCode: 0x2E,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x2E, flags: [.command, .shift]))
        XCTAssertEqual(delegate.micToggleCount, 1)
    }

    func testCustomModeToggleShortcutTriggersDelegate() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.modeToggleShortcut = GlobalShortcut(
            keyCode: 0x2F,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        XCTAssertTrue(monitor.handleKeyDown(keyCode: 0x2F, flags: [.command, .shift]))
        XCTAssertEqual(delegate.modeToggleCount, 1)
    }

    func testDefaultDoubleTapFnTriggersModeToggleWhenNoCustomOverride() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.modeToggleShortcut = nil

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        flushShortcutTimers()
        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        flushShortcutTimers()

        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertEqual(delegate.pttReleaseCount, 1)
        XCTAssertEqual(delegate.modeToggleCount, 1)
    }

    func testRapidDoubleTapFnTriggersModeToggleWhenFnReleaseIsDuplicated() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.modeToggleShortcut = nil

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        flushShortcutTimers()

        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertEqual(delegate.pttReleaseCount, 1)
        XCTAssertEqual(delegate.modeToggleCount, 1)
    }

    func testRapidDoubleTapFnTriggersModeToggleWhenFnPressAndReleaseAreDuplicated() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.modeToggleShortcut = nil

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        flushShortcutTimers()

        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertEqual(delegate.pttReleaseCount, 1)
        XCTAssertEqual(delegate.modeToggleCount, 1)
    }

    func testDoubleTapFnTriggersModeToggleWhenReleaseArrivesWithDifferentKeyCode() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.modeToggleShortcut = nil

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 0, flags: [])
        flushShortcutTimers()
        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 0, flags: [])
        flushShortcutTimers()

        XCTAssertEqual(delegate.pttPressCount, 1)
        XCTAssertEqual(delegate.pttReleaseCount, 1)
        XCTAssertEqual(delegate.modeToggleCount, 1)
    }

    func testCustomModeToggleDisablesDefaultDoubleTapFnGesture() {
        let monitor = GlobalShortcutMonitor()
        let delegate = ShortcutMonitorDelegateSpy()
        monitor.delegate = delegate
        monitor.modeToggleShortcut = GlobalShortcut(
            keyCode: 0x2F,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        flushShortcutTimers()
        monitor.handleFlagsChanged(keyCode: 63, flags: [.function])
        monitor.handleFlagsChanged(keyCode: 63, flags: [])
        flushShortcutTimers()

        XCTAssertEqual(delegate.modeToggleCount, 0)
        XCTAssertEqual(delegate.pttPressCount, 2)
        XCTAssertEqual(delegate.pttReleaseCount, 2)
    }

    private func advancePastKeyDedupWindow() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }

    private func flushShortcutTimers() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    }
}

private final class ShortcutMonitorDelegateSpy: GlobalShortcutDelegate {
    var pttPressCount = 0
    var pttReleaseCount = 0
    var pttCancelCount = 0
    var toggleCount = 0
    var micToggleCount = 0
    var modeToggleCount = 0
    var isToggleRecordingActive = false

    func pttDidPress() {
        pttPressCount += 1
    }

    func pttDidRelease() {
        pttReleaseCount += 1
    }

    func pttDidCancel() {
        pttCancelCount += 1
    }

    func toggleDidPress() {
        toggleCount += 1
        isToggleRecordingActive.toggle()
    }

    func micToggleDidTrigger() {
        micToggleCount += 1
    }

    func modeToggleDidTrigger() {
        modeToggleCount += 1
    }

    func isToggleRecordingActiveForShortcuts() -> Bool {
        isToggleRecordingActive
    }
}
