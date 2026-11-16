import Foundation
import AudioToolbox
import CoreAudio
import MSCore
import MSProtocol

/// Source of interleaved s16le stereo 48 kHz PCM. `onSamples` may be called on a real-time thread and
/// must therefore be cheap (the capture only copies into a ring buffer).
public protocol AudioInputSource: AnyObject {
    func start(onSamples: @escaping (UnsafeRawBufferPointer) -> Void) throws
    func stop()
}

/// Real-time callback -> SPSC ring buffer -> `ms.audio` drain queue -> 240-frame packets (PLAN 6.6, 6.9).
public final class AudioCapture {
    public static let bytesPerFrame = MSConstants.audioChannels * 2
    public static let drainIntervalMs = 2

    private let source: AudioInputSource
    private let send: (AudioPacket) -> Void
    private let ring = SPSCRingBuffer(capacity: MSConstants.audioSampleRate * AudioCapture.bytesPerFrame / 2)
    private let queue = DispatchQueue(label: "ms.audio", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var seq: UInt32 = 0              // queue only
    private var running = false              // caller thread
    private var scratch = [UInt8](repeating: 0, count: AudioPacket.pcmSize)  // queue only

    /// `send` is called on the `ms.audio` queue.
    public init(source: AudioInputSource, send: @escaping (AudioPacket) -> Void) {
        self.source = source
        self.send = send
    }

    public func start() throws {
        guard !running else { return }
        let ring = self.ring
        try source.start { buf in _ = ring.write(buf) }
        running = true
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(Self.drainIntervalMs), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.drain() }
        timer = t
        t.resume()
    }

    public func stop() {
        guard running else { return }
        running = false
        source.stop()
        timer?.cancel()
        timer = nil
        queue.sync {}
    }

    /// Queue only. Emits every complete packet currently buffered.
    private func drain() {
        let size = AudioPacket.pcmSize
        while ring.availableToRead >= size {
            let n = scratch.withUnsafeMutableBytes { ring.read(into: $0) }
            guard n == size else { return }
            let remainingFrames = ring.availableToRead / Self.bytesPerFrame
            let age = UInt64(remainingFrames) * 1_000_000 / UInt64(MSConstants.audioSampleRate)
            let now = MonoClock.nowMicros()
            // Timestamp of the first frame of this packet (approximately): now minus what is still queued
            // minus the packet's own duration.
            let own = UInt64(MSConstants.audioFramesPerPacket) * 1_000_000 / UInt64(MSConstants.audioSampleRate)
            let t = now &- min(now, age &+ own)
            send(AudioPacket(seq: seq, hostTimeMicros: t, pcm: Data(scratch)))
            seq &+= 1
        }
    }
}

// MARK: - Output switching

public typealias AudioDeviceIdentifier = UInt32

public protocol AudioDeviceControlling: AnyObject {
    func deviceID(named name: String) -> AudioDeviceIdentifier?
    func defaultOutput() -> AudioDeviceIdentifier?
    @discardableResult func setDefaultOutput(_ id: AudioDeviceIdentifier) -> Bool
}

public enum AudioSwitchError: Error, Equatable {
    case deviceNotFound
    case setFailed
}

/// Makes the "MacScreen Display" device the system default output and puts the old one back.
public final class AudioOutputSwitcher {
    public static let deviceName = "MacScreen Display"

    private let control: AudioDeviceControlling
    private let name: String
    private var ours: AudioDeviceIdentifier?
    private var previous: AudioDeviceIdentifier?

    public init(control: AudioDeviceControlling, deviceName: String = AudioOutputSwitcher.deviceName) {
        self.control = control
        self.name = deviceName
    }

    public var isDevicePresent: Bool { control.deviceID(named: name) != nil }
    public var isActive: Bool { ours != nil }

    public func enable() throws {
        if ours != nil { return }
        guard let dev = control.deviceID(named: name) else { throw AudioSwitchError.deviceNotFound }
        let current = control.defaultOutput()
        if current != dev { previous = current }
        guard control.setDefaultOutput(dev) else { previous = nil; throw AudioSwitchError.setFailed }
        ours = dev
    }

    /// Restores the remembered device, but only if ours is still the default (the user may have changed it).
    public func restore() {
        guard let dev = ours else { return }
        ours = nil
        let prev = previous
        previous = nil
        if control.defaultOutput() == dev, let p = prev { control.setDefaultOutput(p) }
    }
}

/// CoreAudio-backed implementation. Tests must not use this.
public final class SystemAudioDevices: AudioDeviceControlling {
    public init() {}

    public static func allDevices() -> [AudioDeviceIdentifier] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    public static func name(of id: AudioDeviceIdentifier) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf else { return nil }
        return s.takeRetainedValue() as String
    }

    public func deviceID(named name: String) -> AudioDeviceIdentifier? {
        Self.allDevices().first { Self.name(of: $0) == name }
    }

    public func defaultOutput() -> AudioDeviceIdentifier? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    @discardableResult
    public func setDefaultOutput(_ id: AudioDeviceIdentifier) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(id)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }
}

// MARK: - AUHAL input

public enum AudioInputError: Error {
    case deviceNotFound(String)
    case coreAudio(String, OSStatus)
}

/// Reads the input side of a named device through an AUHAL unit, converted to s16le stereo 48 kHz.
/// Opening it may trigger the microphone permission prompt; tests must not use this.
public final class AUHALInputSource: AudioInputSource {
    private let deviceName: String
    private var unit: AudioUnit?
    private var context: Unmanaged<RenderContext>?

    private final class RenderContext {
        var unit: AudioUnit?
        var onSamples: ((UnsafeRawBufferPointer) -> Void)?
        let maxFrames = 4096
        let buffer: UnsafeMutableRawPointer
        init() { buffer = UnsafeMutableRawPointer.allocate(byteCount: maxFrames * AudioCapture.bytesPerFrame, alignment: 16) }
        deinit { buffer.deallocate() }
    }

    public init(deviceName: String = AudioOutputSwitcher.deviceName) { self.deviceName = deviceName }

    public func start(onSamples: @escaping (UnsafeRawBufferPointer) -> Void) throws {
        guard unit == nil else { return }
        guard let dev = SystemAudioDevices().deviceID(named: deviceName) else {
            throw AudioInputError.deviceNotFound(deviceName)
        }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw AudioInputError.coreAudio("find AUHAL", -1) }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "new AUHAL")
        guard let au = u else { throw AudioInputError.coreAudio("new AUHAL", -1) }
        do {
            var on: UInt32 = 1, off: UInt32 = 0
            let sz = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sz), "enable input")
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sz), "disable output")
            var d = AudioDeviceID(dev)
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)), "set device")
            var fmt = AudioStreamBasicDescription(
                mSampleRate: Float64(MSConstants.audioSampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(AudioCapture.bytesPerFrame), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(AudioCapture.bytesPerFrame), mChannelsPerFrame: UInt32(MSConstants.audioChannels),
                mBitsPerChannel: 16, mReserved: 0)
            try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set format")
            let ctx = RenderContext()
            ctx.unit = au
            ctx.onSamples = onSamples
            let um = Unmanaged.passRetained(ctx)
            context = um
            var cb = AURenderCallbackStruct(inputProc: { refCon, flags, ts, bus, frames, _ in
                let c = Unmanaged<RenderContext>.fromOpaque(refCon).takeUnretainedValue()
                guard let unit = c.unit, Int(frames) <= c.maxFrames else { return noErr }
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(MSConstants.audioChannels),
                    mDataByteSize: frames * UInt32(AudioCapture.bytesPerFrame), mData: c.buffer))
                let st = AudioUnitRender(unit, flags, ts, bus, frames, &list)
                if st == noErr {
                    c.onSamples?(UnsafeRawBufferPointer(start: c.buffer, count: Int(frames) * AudioCapture.bytesPerFrame))
                }
                return st
            }, inputProcRefCon: um.toOpaque())
            try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set callback")
            try check(AudioUnitInitialize(au), "initialize")
            try check(AudioOutputUnitStart(au), "start")
            unit = au
        } catch {
            context?.release(); context = nil
            AudioComponentInstanceDispose(au)
            throw error
        }
    }

    public func stop() {
        guard let au = unit else { return }
        unit = nil
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        context?.takeUnretainedValue().onSamples = nil
        context?.release(); context = nil
    }

    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw AudioInputError.coreAudio(what, st) }
    }
}
