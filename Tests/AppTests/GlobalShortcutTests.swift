import XCTest
import AppKit
@testable import HotkeyModule

final class GlobalShortcutTests: XCTestCase {
    func testGenericModifierConflictsWithSideSpecificModifier() {
        let genericCommand = GlobalShortcut(
            keyCode: nil,
            modifiers: NSEvent.ModifierFlags.command.rawValue
        )
        let rightCommand = GlobalShortcut(
            keyCode: nil,
            modifiers: NSEvent.ModifierFlags.command.rawValue | 0x00000010,
            modifierKeyCode: 54
        )

        XCTAssertTrue(genericCommand.conflicts(with: rightCommand))
        XCTAssertTrue(rightCommand.conflicts(with: genericCommand))
    }

    func testSideSpecificKeyCombosRemainDistinct() {
        let leftCommandK = GlobalShortcut(
            keyCode: 0x28,
            modifiers: NSEvent.ModifierFlags.command.rawValue | 0x00000008
        )
        let rightCommandK = GlobalShortcut(
            keyCode: 0x28,
            modifiers: NSEvent.ModifierFlags.command.rawValue | 0x00000010
        )

        XCTAssertFalse(leftCommandK.conflicts(with: rightCommandK))
        XCTAssertFalse(rightCommandK.conflicts(with: leftCommandK))
    }

    func testModifierOnlyDisplayUsesPhysicalKeyName() {
        let shortcut = GlobalShortcut(
            keyCode: nil,
            modifiers: NSEvent.ModifierFlags.option.rawValue | 0x00000040,
            modifierKeyCode: 61
        )

        XCTAssertEqual(shortcut.displayString, "Right Option")
    }

    func testMergedModifierRawValueIgnoresStaleUnrequiredBits() {
        let result = GlobalShortcutMonitor.mergedModifierRawValue(
            eventRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            currentRawValue: NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000010,
            requiredRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        XCTAssertEqual(
            GlobalShortcut.normalizedModifierFlags(fromRaw: result),
            NSEvent.ModifierFlags([.command, .shift])
        )
        XCTAssertEqual(GlobalShortcut.deviceDependentModifierRawValue(from: result), 0)
    }

    func testMergedModifierRawValueBackfillsOnlyRequiredFnBit() {
        let result = GlobalShortcutMonitor.mergedModifierRawValue(
            eventRawValue: 0,
            currentRawValue: NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000010,
            requiredRawValue: NSEvent.ModifierFlags.function.rawValue
        )

        XCTAssertEqual(
            GlobalShortcut.normalizedModifierFlags(fromRaw: result),
            NSEvent.ModifierFlags.function
        )
        XCTAssertEqual(GlobalShortcut.deviceDependentModifierRawValue(from: result), 0)
    }

    func testMergedModifierRawValuePreservesRequiredSideSpecificModifier() {
        let result = GlobalShortcutMonitor.mergedModifierRawValue(
            eventRawValue: NSEvent.ModifierFlags.command.rawValue,
            currentRawValue: NSEvent.ModifierFlags.command.rawValue | 0x00000010,
            requiredRawValue: NSEvent.ModifierFlags.command.rawValue | 0x00000010
        )

        XCTAssertEqual(
            GlobalShortcut.normalizedModifierFlags(fromRaw: result),
            NSEvent.ModifierFlags.command
        )
        XCTAssertEqual(GlobalShortcut.deviceDependentModifierRawValue(from: result), 0x00000010)
    }

    func testCarbonHotKeySupportRejectsFnAndSideSpecificCombos() {
        let standardShortcut = GlobalShortcut(
            keyCode: 0x2E,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )
        let fnShortcut = GlobalShortcut(
            keyCode: 0x31,
            modifiers: NSEvent.ModifierFlags.function.rawValue
        )
        let sideSpecificShortcut = GlobalShortcut(
            keyCode: 0x28,
            modifiers: NSEvent.ModifierFlags.command.rawValue | 0x00000010
        )

        XCTAssertTrue(standardShortcut.canUseCarbonHotKey)
        XCTAssertFalse(fnShortcut.canUseCarbonHotKey)
        XCTAssertFalse(sideSpecificShortcut.canUseCarbonHotKey)
    }

    func testMatchesKeyEventRequiresExactModifiers() {
        let shortcut = GlobalShortcut(
            keyCode: 0x2E,
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )

        XCTAssertTrue(
            shortcut.matchesKeyEvent(
                keyCode: 0x2E,
                modifierRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue
            )
        )
        XCTAssertFalse(
            shortcut.matchesKeyEvent(
                keyCode: 0x2E,
                modifierRawValue: NSEvent.ModifierFlags.command.rawValue
            )
        )
    }
}
