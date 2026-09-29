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
///
/// Clamshell: with the lid closed the built-in mic is hardware-disconnected, so it's
/// never chosen then (a wired mic is, if there is one). Closing the lid hands the
/// input back to the headset we moved it off; opening it moves it to the Mac again.
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
    private var lidObserver: NSObjectProtocol?
    /// The headset the guard last moved the default input away from.
    private var displacedHeadsetID: AudioDeviceID?

    /// macOS moves the default input a beat after the headset appears.
    static let arrivalWindow: TimeInterval = 5

    init(query: any CoreAudioQuerying = SystemCoreAudioQuery()) {
        self.query = query
    }

    enum Trigger: Equatable {
        case enabled, devicesChanged, defaultInputChanged, lidOpened
    }

    struct InputDevice: Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: InputTransport
    }

    /// Pure decision: the non-Bluetooth mic to switch to, or nil to leave the default alone.
    static func replacementInput(
        defaultInputID: AudioDeviceID?,
        inputs: [InputDevice],
        trigger: Trigger,
        bluetoothJustArrived: Bool,
        lidClosed: Bool
    ) -> InputDevice? {
        guard let defaultInputID,
              let current = inputs.first(where: { $0.id == defaultInputID }),
              current.transport == .bluetooth else { return nil }
        // A later, deliberate pick of the headset mic is respected.
        guard trigger == .enabled || trigger == .lidOpened || bluetoothJustArrived else { return nil }
        if !lidClosed, let builtIn = inputs.first(where: { $0.transport == .builtIn }) {
            return builtIn
        }
        // Lid closed (or no built-in mic): only a wired mic is better than the headset.
        return inputs.first(where: { $0.transport == .wired })
    }

    /// Pure decision for the lid closing: give the input back to the headset we displaced,
    /// since the built-in mic it was moved to can no longer hear anything.
    static func inputToRestoreOnLidClose(
        defaultInputID: AudioDeviceID?,
        inputs: [InputDevice],
        displacedHeadsetID: AudioDeviceID?
    ) -> InputDevice? {
        guard let displacedHeadsetID,
              let current = inputs.first(where: { $0.id == defaultInputID }),
              current.transport == .builtIn else { return nil }
        return inputs.first(where: { $0.id == displacedHeadsetID && $0.transport == .bluetooth })
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
            bluetoothJustArrived: justArrived,
            lidClosed: query.isLidClosed()
        ) else { return }

        let headsetName = inputs.first(where: { $0.id == defaultID })?.name ?? "Bluetooth headset"
        if Self.setDefaultInputDevice(target.id) {
            displacedHeadsetID = defaultID
            onDiagnostic?("BluetoothInputGuard: default input \"\(headsetName)\" → \"\(target.name)\" (trigger=\(trigger))")
            onSwitchedAwayFromBluetooth?(headsetName)
        } else {
            onDiagnostic?("BluetoothInputGuard: failed to set default input to \"\(target.name)\"")
        }
    }

    private func handleLidChanged() {
        guard isEnabled else { return }
        let inputs = currentInputs()
        let defaultID = query.defaultInputDeviceID()
        if query.isLidClosed() {
            guard let headset = Self.inputToRestoreOnLidClose(
                defaultInputID: defaultID, inputs: inputs, displacedHeadsetID: displacedHeadsetID
            ) else { return }
            if Self.setDefaultInputDevice(headset.id) {
                onDiagnostic?("BluetoothInputGuard: lid closed — built-in mic is off, input back to \"\(headset.name)\"")
            }
        } else if let displacedHeadsetID, displacedHeadsetID == defaultID {
            evaluate(trigger: .lidOpened)
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
        LidStateMonitor.shared.start()
        lidObserver = NotificationCenter.default.addObserver(
            forName: LidStateMonitor.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleLidChanged() }
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
        if let lidObserver { NotificationCenter.default.removeObserver(lidObserver) }
        lidObserver = nil
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
