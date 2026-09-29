import CoreAudio
import XCTest
@testable import AudioEngine

final class BluetoothInputGuardTests: XCTestCase {
    private let builtIn = BluetoothInputGuard.InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn)
    private let airPods = BluetoothInputGuard.InputDevice(id: 2, name: "AirPods Pro", transport: .bluetooth)
    private let usb = BluetoothInputGuard.InputDevice(id: 3, name: "USB Mic", transport: .wired)
    private let loopback = BluetoothInputGuard.InputDevice(id: 4, name: "Loopback", transport: .other)

    private func decide(default id: AudioDeviceID?, inputs: [BluetoothInputGuard.InputDevice]? = nil,
                        trigger: BluetoothInputGuard.Trigger, justArrived: Bool,
                        lidClosed: Bool = false) -> BluetoothInputGuard.InputDevice? {
        BluetoothInputGuard.replacementInput(defaultInputID: id, inputs: inputs ?? [builtIn, airPods, usb],
                                             trigger: trigger, bluetoothJustArrived: justArrived, lidClosed: lidClosed)
    }

    func testAutomaticHopToNewlyConnectedHeadsetIsUndone() {
        XCTAssertEqual(decide(default: 2, trigger: .defaultInputChanged, justArrived: true), builtIn)
        XCTAssertEqual(decide(default: 2, trigger: .devicesChanged, justArrived: true), builtIn)
    }

    func testEnablingFixesAHeadsetThatIsAlreadyTheInput() {
        XCTAssertEqual(decide(default: 2, trigger: .enabled, justArrived: false), builtIn)
    }

    func testDeliberateLaterPickOfHeadsetMicIsRespected() {
        XCTAssertNil(decide(default: 2, trigger: .defaultInputChanged, justArrived: false))
    }

    func testNonBluetoothDefaultsAreLeftAlone() {
        XCTAssertNil(decide(default: 1, trigger: .enabled, justArrived: true))
        XCTAssertNil(decide(default: 3, trigger: .defaultInputChanged, justArrived: true))
    }

    func testNoBuiltInMicUsesAWiredMicIfThereIsOne() {
        // Mac mini / Studio with a USB or display mic.
        XCTAssertEqual(decide(default: 2, inputs: [airPods, usb], trigger: .enabled, justArrived: true), usb)
    }

    func testOnlyVirtualDevicesMeansNoSwitch() {
        XCTAssertNil(decide(default: 2, inputs: [airPods, loopback], trigger: .enabled, justArrived: true))
    }

    // MARK: Clamshell

    func testLidClosedNeverSwitchesToTheDeafBuiltInMic() {
        XCTAssertNil(decide(default: 2, inputs: [builtIn, airPods], trigger: .defaultInputChanged,
                            justArrived: true, lidClosed: true))
    }

    func testLidClosedPrefersAWiredMicOverTheHeadset() {
        XCTAssertEqual(decide(default: 2, trigger: .enabled, justArrived: false, lidClosed: true), usb)
    }

    func testLidOpeningMovesTheInputBackToTheMac() {
        XCTAssertEqual(decide(default: 2, trigger: .lidOpened, justArrived: false), builtIn)
    }

    func testLidClosingHandsTheInputBackToTheDisplacedHeadset() {
        let restored = BluetoothInputGuard.inputToRestoreOnLidClose(
            defaultInputID: 1, inputs: [builtIn, airPods, usb], displacedHeadsetID: 2)
        XCTAssertEqual(restored, airPods)
    }

    func testLidClosingLeavesInputsTheGuardDidNotMove() {
        XCTAssertNil(BluetoothInputGuard.inputToRestoreOnLidClose(
            defaultInputID: 1, inputs: [builtIn, airPods], displacedHeadsetID: nil))
        // Already moved to a wired mic, which still works with the lid closed.
        XCTAssertNil(BluetoothInputGuard.inputToRestoreOnLidClose(
            defaultInputID: 3, inputs: [builtIn, airPods, usb], displacedHeadsetID: 2))
        // Headset has since disconnected.
        XCTAssertNil(BluetoothInputGuard.inputToRestoreOnLidClose(
            defaultInputID: 1, inputs: [builtIn, usb], displacedHeadsetID: 2))
    }

    func testUnknownDefaultIsLeftAlone() {
        XCTAssertNil(decide(default: nil, trigger: .enabled, justArrived: true))
        XCTAssertNil(decide(default: 99, trigger: .enabled, justArrived: true))
    }
}
