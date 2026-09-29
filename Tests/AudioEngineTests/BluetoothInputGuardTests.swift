import CoreAudio
import XCTest
@testable import AudioEngine

final class BluetoothInputGuardTests: XCTestCase {
    private let builtIn = BluetoothInputGuard.InputDevice(id: 1, name: "MacBook Pro Microphone", transport: .builtIn)
    private let airPods = BluetoothInputGuard.InputDevice(id: 2, name: "AirPods Pro", transport: .bluetooth)
    private let usb = BluetoothInputGuard.InputDevice(id: 3, name: "USB Mic", transport: .other)

    private func decide(default id: AudioDeviceID?, inputs: [BluetoothInputGuard.InputDevice]? = nil,
                        trigger: BluetoothInputGuard.Trigger, justArrived: Bool) -> BluetoothInputGuard.InputDevice? {
        BluetoothInputGuard.replacementInput(defaultInputID: id, inputs: inputs ?? [builtIn, airPods, usb],
                                             trigger: trigger, bluetoothJustArrived: justArrived)
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

    func testNoBuiltInMicMeansNoSwitch() {
        // Mac mini / Studio: nothing better to switch to.
        XCTAssertNil(decide(default: 2, inputs: [airPods, usb], trigger: .enabled, justArrived: true))
    }

    func testUnknownDefaultIsLeftAlone() {
        XCTAssertNil(decide(default: nil, trigger: .enabled, justArrived: true))
        XCTAssertNil(decide(default: 99, trigger: .enabled, justArrived: true))
    }
}
