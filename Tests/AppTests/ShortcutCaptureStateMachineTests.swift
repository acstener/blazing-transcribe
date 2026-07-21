import XCTest
import AppKit
@testable import App

final class ShortcutCaptureStateMachineTests: XCTestCase {
    func testCapturesFnPlusLeftCommandOnFirstModifierRelease() {
        var stateMachine = ShortcutCaptureStateMachine()

        XCTAssertNil(
            stateMachine.handleFlagsChanged(
                keyCode: 63,
                modifierRawValue: NSEvent.ModifierFlags.function.rawValue
            )
        )
        XCTAssertNil(
            stateMachine.handleFlagsChanged(
                keyCode: 55,
                modifierRawValue: NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000008
            )
        )

        let captured = stateMachine.handleFlagsChanged(
            keyCode: 55,
            modifierRawValue: NSEvent.ModifierFlags.function.rawValue
        )

        XCTAssertEqual(captured?.keyCode, nil)
        XCTAssertEqual(
            captured?.modifiers.rawValue,
            NSEvent.ModifierFlags([.function, .command]).rawValue | 0x00000008
        )
        XCTAssertNil(captured?.modifierKeyCode)
    }

    func testSingleSideSpecificModifierKeepsPhysicalKeyCode() {
        var stateMachine = ShortcutCaptureStateMachine()

        XCTAssertNil(
            stateMachine.handleFlagsChanged(
                keyCode: 55,
                modifierRawValue: NSEvent.ModifierFlags.command.rawValue | 0x00000008
            )
        )

        let captured = stateMachine.handleFlagsChanged(
            keyCode: 55,
            modifierRawValue: 0
        )

        XCTAssertEqual(captured?.keyCode, nil)
        XCTAssertEqual(captured?.modifiers.rawValue, NSEvent.ModifierFlags.command.rawValue | 0x00000008)
        XCTAssertEqual(captured?.modifierKeyCode, 55)
    }
}
