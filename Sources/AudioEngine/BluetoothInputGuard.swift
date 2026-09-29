import CoreAudio
import Foundation

/// Experimental: keeps the Mac's *system* default input off Bluetooth headsets.
///
/// Opening a Bluetooth headset's mic (from any app — Zoom, Shazam, Siri) drops it
/// from high-quality A2DP to call-quality HFP. `AudioCaptureService` already avoids
/// that for Blazing's own recordings; this goes further, like CrystalClear Sound:
/// when macOS auto-switches the default input to newly connected Bluetooth
/// headphones, switch it back to the built-in mic.
///
/// Only the automatic hop that follows a device connecting is undone, so picking
/// AirPods as the input in System Settings later is respected.
public final class BluetoothInputGuard {
    public static let shared = BluetoothInputGuard()

    /// Receives one-line diagnostics (switches, errors).
    public var onDiagnostic: ((String) -> Void)?
    /// Called after the guard moves the default input, with the headset's name.
    public var onSwitchedAwayFromBluetooth: ((String) -> Void)?

    public var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                installListeners()
                evaluate(trigger: .enabled)
            } else {
                removeListeners()
            }
        }
    }

    private let query: any CoreAudioQuerying
    private var lastDeviceArrivalAt: Date?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var knownDeviceIDs: Set<AudioDeviceID> = []

    /// macOS moves the default input a beat after the headset appears.
    static let arrivalWindow: TimeInterval = 5

    init(query: any CoreAudioQuerying = SystemCoreAudioQuery()) {
        self.query = query
    }

    enum Trigger: Equatable {
        case enabled, devicesChanged, defaultInputChanged
    }

    struct InputDevice: Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: InputTransport
    }

    /// Pure decision: the built-in mic to switch to, or nil to leave the default alone.
    static func replacementInput(
        defaultInputID: AudioDeviceID?,
        inputs: [InputDevice],
        trigger: Trigger,
        bluetoothJustArrived: Bool
    ) -> InputDevice? {
        guard let defaultInputID,
              let current = inputs.first(where: { $0.id == defaultInputID }),
              current.transport == .bluetooth else { return nil }
        // A later, deliberate pick of the headset mic is respected.
        guard trigger == .enabled || bluetoothJustArrived else { return nil }
        return inputs.first(where: { $0.transport == .builtIn })
    }

    private func currentInputs() -> [InputDevice] {
        AudioCaptureService.availableInputDevices(using: query).map {
            InputDevice(id: $0.id, name: $0.name,
                        transport: InputTransport(rawTransport: query.transportType(deviceID: $0.id)))
        }
    }

    private func evaluate(trigger: Trigger) {
        guard isEnabled else { return }
        let inputs = currentInputs()
        let justArrived = lastDeviceArrivalAt.map { Date().timeIntervalSince($0) < Self.arrivalWindow } ?? false
        let defaultID = query.defaultInputDeviceID()
        guard let target = Self.replacementInput(
            defaultInputID: defaultID,
            inputs: inputs,
            trigger: trigger,
            bluetoothJustArrived: justArrived
        ) else { return }

        let headsetName = inputs.first(where: { $0.id == defaultID })?.name ?? "Bluetooth headset"
        if Self.setDefaultInputDevice(target.id) {
            onDiagnostic?("BluetoothInputGuard: default input \"\(headsetName)\" → \"\(target.name)\" (trigger=\(trigger))")
            onSwitchedAwayFromBluetooth?(headsetName)
        } else {
            onDiagnostic?("BluetoothInputGuard: failed to set default input to \"\(target.name)\"")
        }
    }

    private func handleDevicesChanged() {
        let ids = Set(query.deviceIDs())
        let added = ids.subtracting(knownDeviceIDs)
        knownDeviceIDs = ids
        let bluetoothArrived = added.contains {
            InputTransport(rawTransport: query.transportType(deviceID: $0)) == .bluetooth
        }
        guard bluetoothArrived else { return }
        lastDeviceArrivalAt = Date()
        evaluate(trigger: .devicesChanged)
    }

    // MARK: - CoreAudio plumbing

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installListeners() {
        guard devicesListener == nil else { return }
        knownDeviceIDs = Set(query.deviceIDs())
        let devices: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.handleDevicesChanged() }
        let defaultInput: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluate(trigger: .defaultInputChanged)
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = Self.devicesAddress
        var defaultInputAddress = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(system, &devicesAddress, .main, devices)
        AudioObjectAddPropertyListenerBlock(system, &defaultInputAddress, .main, defaultInput)
        devicesListener = devices
        defaultInputListener = defaultInput
    }

    private func removeListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddress = Self.devicesAddress
        var defaultInputAddress = Self.defaultInputAddress
        if let devicesListener {
            AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, .main, devicesListener)
        }
        if let defaultInputListener {
            AudioObjectRemovePropertyListenerBlock(system, &defaultInputAddress, .main, defaultInputListener)
        }
        devicesListener = nil
        defaultInputListener = nil
        lastDeviceArrivalAt = nil
    }

    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var address = defaultInputAddress
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        ) == noErr
    }
}
