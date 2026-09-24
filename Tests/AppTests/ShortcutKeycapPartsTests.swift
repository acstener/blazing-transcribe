import XCTest
import AppKit
@testable import App
@testable import HotkeyModule

final class ShortcutKeycapPartsTests: XCTestCase {
    func testSingleKey() {
        XCTAssertEqual(ShortcutKeycapParts.split("fn"), ["fn"])
    }

    func testModifierPlusKey() {
        XCTAssertEqual(ShortcutKeycapParts.split("fn Space"), ["fn", "Space"])
        XCTAssertEqual(ShortcutKeycapParts.split("⌥ ⌘ M"), ["⌥", "⌘", "M"])
    }

    func testSidedModifierNamesStayOneCap() {
        XCTAssertEqual(ShortcutKeycapParts.split("Right Command"), ["Right Command"])
        XCTAssertEqual(ShortcutKeycapParts.split("Left Option"), ["Left Option"])
    }

    func testPlusSeparatorsAndExtraWhitespace() {
        XCTAssertEqual(ShortcutKeycapParts.split("  ⌘ + ⇧ +  L "), ["⌘", "⇧", "L"])
    }

    func testEmpty() {
        XCTAssertEqual(ShortcutKeycapParts.split(""), [])
        XCTAssertEqual(ShortcutKeycapParts.split("   "), [])
    }

    func testRealShortcutDisplayStrings() {
        XCTAssertEqual(ShortcutKeycapParts.split(GlobalShortcut.defaultPTT.displayString), ["fn"])
        XCTAssertEqual(ShortcutKeycapParts.split(GlobalShortcut.defaultToggle.displayString), ["fn", "Space"])
        XCTAssertEqual(ShortcutKeycapParts.split(StoredShortcut.defaultMicToggle.displayString), ["⇧", "⌘", "M"])
        let rightCommand = GlobalShortcut(keyCode: nil, modifiers: NSEvent.ModifierFlags.command.rawValue, modifierKeyCode: 54)
        XCTAssertEqual(ShortcutKeycapParts.split(rightCommand.displayString), ["Right Command"])
    }

    func testKeycapPressedOnlyInManualMode() {
        let model = AppViewModel()
        model.recordingMode = .manual
        XCTAssertFalse(model.isShortcutKeycapPressed)
        model.isShortcutHeld = true
        XCTAssertTrue(model.isShortcutKeycapPressed)
        model.isShortcutHeld = false
        model.isToggleRecordingActive = true
        XCTAssertTrue(model.isShortcutKeycapPressed)
        model.recordingMode = .alwaysOn
        XCTAssertFalse(model.isShortcutKeycapPressed)
    }

    func testRejectionReleasesAndBumpsCounter() {
        let model = AppViewModel()
        model.isShortcutHeld = true
        model.noteShortcutRejected()
        XCTAssertFalse(model.isShortcutHeld)
        XCTAssertEqual(model.shortcutRejectionCount, 1)
    }
}
