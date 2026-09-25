import AudioToolbox
import AVFoundation
import Foundation

internal protocol CoreAudioQuerying {
    func deviceIDs() -> [AudioDeviceID]
    func inputStreamConfiguration(deviceID: AudioDeviceID) -> Data?
    func deviceName(deviceID: AudioDeviceID) -> String?
    func inputStreamFormat(deviceID: AudioDeviceID) -> AVAudioFormat?
    func defaultInputDeviceID() -> AudioDeviceID?
    func transportType(deviceID: AudioDeviceID) -> UInt32?
}

extension CoreAudioQuerying {
    /// Default for test stubs that don't model transports.
    func transportType(deviceID: AudioDeviceID) -> UInt32? { nil }
}

internal enum InputTransport: Equatable {
    case builtIn, bluetooth, other

    init(rawTransport: UInt32?) {
        switch rawTransport {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        default: self = .other
        }
    }
}

internal struct SystemCoreAudioQuery: CoreAudioQuerying {
    func deviceIDs() -> [AudioDeviceID] {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize) == noErr else {
            return []
        }

        let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize,
            &devices
        ) == noErr else {
            return []
        }
        return devices
    }

    func inputStreamConfiguration(deviceID: AudioDeviceID) -> Data? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &inputSize) == noErr else {
            return nil
        }
        guard inputSize > 0 else { return Data() }

        var data = Data(count: Int(inputSize))
        var actualSize = inputSize
        let status: OSStatus = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return kAudio_ParamError }
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &actualSize, baseAddress)
        }
        guard status == noErr else { return nil }

        if Int(actualSize) < data.count {
            data = Data(data.prefix(Int(actualSize)))
        }
        return data
    }

    func deviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) { namePtr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, namePtr)
        }
        guard status == noErr, let name else { return nil }
        let value = name as String
        return value.isEmpty ? nil : value
    }

    func inputStreamFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr else {
            return nil
        }
        return AVAudioFormat(streamDescription: &asbd)
    }

    func transportType(deviceID: AudioDeviceID) -> UInt32? {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return nil
        }
        return deviceID
    }
}

internal enum StartFailureAction: Equatable {
    case ignoreStale
    case scheduleRetry(delay: TimeInterval, attempt: Int, forceSystemDefault: Bool)
    case giveUp
}

internal struct StartCoordinator {
    private(set) var cycleID: Int = 0
    private(set) var retryCount: Int = 0

    mutating func beginCycle() -> Int {
        cycleID += 1
        retryCount = 0
        return cycleID
    }

    mutating func invalidateCycle() -> Int {
        beginCycle()
    }

    mutating func markSuccess() {
        retryCount = 0
    }

    mutating func actionForFailure(
        inCycle cycleID: Int,
        didPinPreferred _: Bool,
        forceSystemDefault: Bool,
        maxRetries: Int = 3
    ) -> StartFailureAction {
        guard cycleID == self.cycleID else { return .ignoreStale }

        guard retryCount < maxRetries else {
            retryCount = 0
            return .giveUp
        }

        let delay = 0.5 * pow(2.0, Double(retryCount))
        retryCount += 1
        return .scheduleRetry(delay: delay, attempt: retryCount, forceSystemDefault: forceSystemDefault)
    }
}
