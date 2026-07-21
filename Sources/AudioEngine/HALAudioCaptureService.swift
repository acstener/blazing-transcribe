import AudioToolbox
import AudioUnit
import AVFoundation
import Foundation

internal struct AudioCaptureBackendStartInfo {
    let deviceID: AudioDeviceID
    let deviceName: String
    let nativeFormat: AVAudioFormat
}

internal protocol AudioCaptureBackend: AnyObject {
    var onFirstCallback: (() -> Void)? { get set }
    var onData: ((_ samples: UnsafeBufferPointer<Float>, _ rms: Float) -> Void)? { get set }
    func start(deviceID: AudioDeviceID?) throws -> AudioCaptureBackendStartInfo
    func stop()
}

internal final class HALAudioCaptureService: AudioCaptureBackend {
    var onFirstCallback: (() -> Void)?
    var onData: ((_ samples: UnsafeBufferPointer<Float>, _ rms: Float) -> Void)?

    private let query: any CoreAudioQuerying
    private let targetFormat: AVAudioFormat
    private let maximumFramesPerSlice: UInt32

    private var audioUnit: AudioUnit?
    private var renderBuffer: HALRenderBuffer?
    private var converter: AVAudioConverter?
    private var isActive = false
    private var didEmitFirstCallback = false

    init(
        query: any CoreAudioQuerying,
        targetSampleRate: Double,
        targetChannels: AVAudioChannelCount,
        maximumFramesPerSlice: UInt32 = 4096
    ) {
        self.query = query
        self.maximumFramesPerSlice = maximumFramesPerSlice
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        )!
    }

    deinit {
        stop()
    }

    func start(deviceID: AudioDeviceID?) throws -> AudioCaptureBackendStartInfo {
        stop()

        guard let resolvedDeviceID = deviceID ?? query.defaultInputDeviceID() else {
            throw AudioCaptureError.noInputDevice
        }
        guard let deviceName = query.deviceName(deviceID: resolvedDeviceID), !deviceName.isEmpty else {
            throw AudioCaptureError.noInputDevice
        }

        let unit = try makeAudioUnit()
        do {
            try configure(unit: unit, deviceID: resolvedDeviceID)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        guard let nativeFormat = try nativeFormat(for: unit, deviceID: resolvedDeviceID) else {
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.noInputDevice
        }

        let clientFormat = try clientFormat(from: nativeFormat)
        let renderBuffer = HALRenderBuffer(format: clientFormat, maximumFrames: maximumFramesPerSlice)
        let converter = makeConverter(from: clientFormat, to: targetFormat)
        var callback = AURenderCallbackStruct(
            inputProc: halInputCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        var maxFrames = maximumFramesPerSlice
        let callbackStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(callbackStatus, message: "Failed to set HAL input callback"))
        }

        let maxFramesStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard maxFramesStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(maxFramesStatus, message: "Failed to set max frames per slice"))
        }

        var clientASBD = clientFormat.streamDescription.pointee
        let formatStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &clientASBD,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard formatStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(formatStatus, message: "Failed to set HAL client format"))
        }

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(initStatus, message: "Failed to initialize HAL audio unit"))
        }

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(startStatus, message: "Failed to start HAL audio unit"))
        }

        self.audioUnit = unit
        self.renderBuffer = renderBuffer
        self.converter = converter
        self.isActive = true
        self.didEmitFirstCallback = false

        return AudioCaptureBackendStartInfo(
            deviceID: resolvedDeviceID,
            deviceName: deviceName,
            nativeFormat: nativeFormat
        )
    }

    func stop() {
        isActive = false

        guard let unit = audioUnit else {
            renderBuffer = nil
            converter = nil
            didEmitFirstCallback = false
            return
        }

        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)

        audioUnit = nil
        renderBuffer = nil
        converter = nil
        didEmitFirstCallback = false
    }

    private func makeAudioUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.engineStartFailed(
                NSError(
                    domain: "AudioEngine",
                    code: -20,
                    userInfo: [NSLocalizedDescriptionKey: "HAL output component not found"]
                )
            )
        }

        var maybeUnit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &maybeUnit)
        guard status == noErr, let unit = maybeUnit else {
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(status, message: "Failed to create HAL output component"))
        }
        return unit
    }

    private func configure(unit: AudioUnit, deviceID: AudioDeviceID) throws {
        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        var currentDeviceID = deviceID

        let inputStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard inputStatus == noErr else {
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(inputStatus, message: "Failed to enable AUHAL input bus"))
        }

        let outputStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard outputStatus == noErr else {
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(outputStatus, message: "Failed to disable AUHAL output bus"))
        }

        let deviceStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            throw AudioCaptureError.engineStartFailed(Self.osStatusError(deviceStatus, message: "Failed to bind AUHAL to the selected input device"))
        }
    }

    private func nativeFormat(for unit: AudioUnit, deviceID: AudioDeviceID) throws -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &asbd,
            &size
        )

        if status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0, let audioFormat = AVAudioFormat(streamDescription: &asbd) {
            return audioFormat
        }

        return query.inputStreamFormat(deviceID: deviceID)
    }

    private func clientFormat(from nativeFormat: AVAudioFormat) throws -> AVAudioFormat {
        let normalized = AudioCaptureService.normalizedTapFormat(from: nativeFormat)
        guard let normalized else {
            throw AudioCaptureError.noInputDevice
        }
        return normalized
    }

    private func makeConverter(from source: AVAudioFormat, to destination: AVAudioFormat) -> AVAudioConverter? {
        guard source.sampleRate != destination.sampleRate || source.channelCount != destination.channelCount else {
            return nil
        }
        return AVAudioConverter(from: source, to: destination)
    }

    fileprivate func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inNumberFrames: UInt32
    ) -> OSStatus {
        guard isActive, let unit = audioUnit, let renderBuffer else {
            return noErr
        }

        renderBuffer.prepare(frameCount: inNumberFrames)
        let renderStatus = AudioUnitRender(
            unit,
            ioActionFlags,
            inTimeStamp,
            1,
            inNumberFrames,
            renderBuffer.audioBufferList
        )
        guard renderStatus == noErr else {
            return renderStatus
        }

        if !didEmitFirstCallback {
            didEmitFirstCallback = true
            DispatchQueue.main.async { [weak self] in
                self?.onFirstCallback?()
            }
        }

        withProcessedSamples(renderBuffer: renderBuffer, frameCount: inNumberFrames) { [weak self] samples in
            guard let self else { return }
            let rms = Self.rms(of: samples)
            self.onData?(samples, rms)
        }

        return noErr
    }

    private func withProcessedSamples(
        renderBuffer: HALRenderBuffer,
        frameCount: UInt32,
        body: (UnsafeBufferPointer<Float>) -> Void
    ) {
        guard let inputBuffer = renderBuffer.makePCMBuffer(frameCount: frameCount) else { return }

        if let converter {
            let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
            let estimatedFrameCapacity = max(Int(ceil(Double(frameCount) * ratio)) + 32, 1)
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: AVAudioFrameCount(estimatedFrameCapacity)
            ) else {
                return
            }

            var conversionError: NSError?
            var didProvideInput = false
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            guard conversionError == nil, status != .error, let channelData = outputBuffer.floatChannelData else {
                return
            }

            let samples = UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
            guard !samples.isEmpty else { return }
            body(samples)
            return
        }

        guard let channelData = inputBuffer.floatChannelData else { return }
        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(inputBuffer.frameLength))
        guard !samples.isEmpty else { return }
        body(samples)
    }

    private static func rms(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        return sqrtf(sumSquares / Float(samples.count))
    }

    private static func osStatusError(_ status: OSStatus, message: String) -> NSError {
        NSError(
            domain: "AudioEngine",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(message) (\(status))"]
        )
    }
}

private final class HALRenderBuffer {
    let format: AVAudioFormat
    let maximumFrames: UInt32
    let audioBufferList: UnsafeMutablePointer<AudioBufferList>

    private let rawAudioBufferList: UnsafeMutableRawPointer
    private let channelStorage: [UnsafeMutablePointer<Float>]

    init(format: AVAudioFormat, maximumFrames: UInt32) {
        self.format = format
        self.maximumFrames = maximumFrames

        let channelCount = Int(format.channelCount)
        let byteCount = MemoryLayout<AudioBufferList>.size + max(channelCount - 1, 0) * MemoryLayout<AudioBuffer>.size
        rawAudioBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawAudioBufferList.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        audioBufferList = rawAudioBufferList.assumingMemoryBound(to: AudioBufferList.self)
        audioBufferList.pointee.mNumberBuffers = UInt32(channelCount)

        channelStorage = (0..<channelCount).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: Int(maximumFrames))
            pointer.initialize(repeating: 0, count: Int(maximumFrames))
            return pointer
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for index in 0..<channelCount {
            buffers[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: maximumFrames * UInt32(MemoryLayout<Float>.size),
                mData: channelStorage[index]
            )
        }
    }

    deinit {
        for pointer in channelStorage {
            pointer.deinitialize(count: Int(maximumFrames))
            pointer.deallocate()
        }
        rawAudioBufferList.deallocate()
    }

    func prepare(frameCount: UInt32) {
        let dataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for index in 0..<buffers.count {
            buffers[index].mDataByteSize = dataByteSize
        }
    }

    func makePCMBuffer(frameCount: UInt32) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: audioBufferList,
            deallocator: nil
        ) else {
            return nil
        }
        buffer.frameLength = frameCount
        return buffer
    }
}

private func halInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber _: UInt32,
    inNumberFrames: UInt32,
    ioData _: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let service = Unmanaged<HALAudioCaptureService>.fromOpaque(inRefCon).takeUnretainedValue()
    return service.handleInput(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inNumberFrames: inNumberFrames
    )
}
