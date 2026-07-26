import CoreAudio
import Darwin
import Foundation

enum CoreAudioProcessFamily {
    static func contains(
        _ candidate: Int32,
        root: Int32,
        parentOf: (Int32) -> Int32?
    ) -> Bool {
        var current = candidate
        var visited = Set<Int32>()
        while current > 1, visited.insert(current).inserted {
            if current == root { return true }
            guard let parent = parentOf(current) else { return false }
            current = parent
        }
        return false
    }
}

/// Resolves a PID through `kAudioHardwarePropertyTranslatePIDToProcessObject`.
public struct CoreAudioProcessObjectResolver: ProcessObjectResolving, Sendable {
    public init() {}

    public func processObjectID(for processID: Int32) throws -> UInt32 {
        var pid = processID
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &objectID
        )
        guard status == noErr else { throw CaptureError.system(status) }
        guard objectID != kAudioObjectUnknown else { throw CaptureError.processNotFound(processID) }
        return objectID
    }

    public func processObjectIDs(forApplicationProcessID processID: Int32) throws -> [UInt32] {
        let matchingObjectIDs = try audioProcessDescriptors()
            .filter {
                CoreAudioProcessFamily.contains(
                    $0.processID,
                    root: processID,
                    parentOf: Self.parentProcessID
                )
            }
            .map(\.objectID)
        if !matchingObjectIDs.isEmpty {
            return Array(Set(matchingObjectIDs)).sorted()
        }
        return [try processObjectID(for: processID)]
    }

    private func audioProcessDescriptors() throws -> [(objectID: UInt32, processID: Int32)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        )
        guard status == noErr else { throw CaptureError.system(status) }
        guard byteCount > 0 else { return [] }

        var objectIDs = Array(
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(byteCount) / MemoryLayout<AudioObjectID>.size
        )
        status = objectIDs.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                bytes.baseAddress!
            )
        }
        guard status == noErr else { throw CaptureError.system(status) }

        return objectIDs.compactMap { objectID in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let pidStatus = AudioObjectGetPropertyData(
                objectID,
                &pidAddress,
                0,
                nil,
                &pidSize,
                &pid
            )
            guard pidStatus == noErr, pid > 0 else { return nil }
            return (objectID, Int32(pid))
        }
    }

    private static func parentProcessID(for processID: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytesRead = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard bytesRead == expectedSize else { return nil }
        return Int32(info.pbi_ppid)
    }
}

public enum CoreAudioSampleEncoding: Sendable, Equatable {
    case float32
    case signedInt16
}

public struct CoreAudioInputFormat: Sendable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    public let encoding: CoreAudioSampleEncoding
    public let interleaved: Bool

    public init(sampleRate: Double, channels: Int, encoding: CoreAudioSampleEncoding, interleaved: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.encoding = encoding
        self.interleaved = interleaved
    }
}

public struct CoreAudioInputBuffer: Sendable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    public let samples: [Float]

    public init(sampleRate: Double, channels: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }
}

public enum CoreAudioAudioBufferConverter {
    public static func convert(
        _ audioBufferList: UnsafePointer<AudioBufferList>,
        format: CoreAudioInputFormat
    ) -> CoreAudioInputBuffer? {
        guard format.sampleRate > 0, format.channels > 0 else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        guard !buffers.isEmpty else { return nil }
        let bytesPerSample = format.encoding == .float32
            ? MemoryLayout<Float>.size
            : MemoryLayout<Int16>.size

        if format.interleaved {
            guard buffers.count == 1, let data = buffers[0].mData else { return nil }
            let sampleCount = Int(buffers[0].mDataByteSize) / bytesPerSample
            guard sampleCount > 0, sampleCount.isMultiple(of: format.channels) else { return nil }
            return CoreAudioInputBuffer(
                sampleRate: format.sampleRate,
                channels: format.channels,
                samples: readSamples(data, count: sampleCount, encoding: format.encoding)
            )
        }

        guard buffers.count >= format.channels else { return nil }
        let frameCounts = buffers.prefix(format.channels).map {
            Int($0.mDataByteSize) / bytesPerSample
        }
        guard let frameCount = frameCounts.min(), frameCount > 0 else { return nil }
        var interleaved = Array(repeating: Float.zero, count: frameCount * format.channels)
        for channel in 0..<format.channels {
            guard let data = buffers[channel].mData else { return nil }
            let channelSamples = readSamples(data, count: frameCount, encoding: format.encoding)
            for frame in 0..<frameCount {
                interleaved[frame * format.channels + channel] = channelSamples[frame]
            }
        }
        return CoreAudioInputBuffer(
            sampleRate: format.sampleRate,
            channels: format.channels,
            samples: interleaved
        )
    }

    private static func readSamples(
        _ data: UnsafeMutableRawPointer,
        count: Int,
        encoding: CoreAudioSampleEncoding
    ) -> [Float] {
        switch encoding {
        case .float32:
            let values = data.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: values, count: count))
        case .signedInt16:
            let values = data.assumingMemoryBound(to: Int16.self)
            return (0..<count).map { Float(values[$0]) / 32_768 }
        }
    }
}

public enum CoreAudioTapMuteBehavior: Sendable, Equatable {
    case unmuted
    case mutedWhenTapped
}

public struct CoreAudioTapConfiguration: Sendable, Equatable {
    public let includedProcessObjectIDs: [AudioObjectID]
    public let excludedProcessObjectIDs: [AudioObjectID]
    public let muteBehavior: CoreAudioTapMuteBehavior

    public init(
        includedProcessObjectIDs: [AudioObjectID] = [],
        excludedProcessObjectIDs: [AudioObjectID] = [],
        muteBehavior: CoreAudioTapMuteBehavior = .unmuted
    ) {
        self.includedProcessObjectIDs = includedProcessObjectIDs
        self.excludedProcessObjectIDs = excludedProcessObjectIDs
        self.muteBehavior = muteBehavior
    }
}

public struct CoreAudioTapHandle: Sendable, Equatable {
    public let id: AudioObjectID
    public let uuid: UUID
    public let format: CoreAudioInputFormat

    public init(
        id: AudioObjectID,
        uuid: UUID,
        format: CoreAudioInputFormat = CoreAudioInputFormat(
            sampleRate: 48_000,
            channels: 1,
            encoding: .float32,
            interleaved: true
        )
    ) {
        self.id = id
        self.uuid = uuid
        self.format = format
    }
}

public struct CoreAudioAggregateDeviceHandle: Sendable, Equatable {
    public let id: AudioObjectID
    public init(id: AudioObjectID) { self.id = id }
}

public struct CoreAudioIOProcHandle: Sendable, Equatable {
    public let token: UInt64
    public init(token: UInt64) { self.token = token }
}

@available(macOS 14.2, *)
public protocol CoreAudioProcessTapAPI: AnyObject, Sendable {
    func createProcessTap(_ configuration: CoreAudioTapConfiguration) throws -> CoreAudioTapHandle
    func destroyProcessTap(_ tap: CoreAudioTapHandle)
    func createAggregateDevice(for tap: CoreAudioTapHandle) throws -> CoreAudioAggregateDeviceHandle
    func destroyAggregateDevice(_ device: CoreAudioAggregateDeviceHandle)
    func createIOProc(
        for device: CoreAudioAggregateDeviceHandle,
        format: CoreAudioInputFormat,
        onInput: @escaping @Sendable (CoreAudioInputBuffer) -> Void
    ) throws -> CoreAudioIOProcHandle
    func destroyIOProc(_ proc: CoreAudioIOProcHandle, from device: CoreAudioAggregateDeviceHandle)
    func startDevice(_ device: CoreAudioAggregateDeviceHandle, proc: CoreAudioIOProcHandle) throws
    func stopDevice(_ device: CoreAudioAggregateDeviceHandle, proc: CoreAudioIOProcHandle)
}

@available(macOS 14.2, *)
public final class SystemCoreAudioProcessTapAPI: CoreAudioProcessTapAPI, @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "com.mimi-for-mac.process-tap.io", qos: .userInitiated)
    private var nextToken: UInt64 = 1
    private var ioProcIDs: [UInt64: AudioDeviceIOProcID] = [:]

    public init() {}

    public func createProcessTap(_ configuration: CoreAudioTapConfiguration) throws -> CoreAudioTapHandle {
        let description: CATapDescription
        if !configuration.includedProcessObjectIDs.isEmpty {
            description = CATapDescription(stereoMixdownOfProcesses: configuration.includedProcessObjectIDs)
        } else {
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: configuration.excludedProcessObjectIDs
            )
        }
        description.name = "Mimi for Mac Process Tap"
        description.muteBehavior = switch configuration.muteBehavior {
        case .unmuted: .unmuted
        case .mutedWhenTapped: .mutedWhenTapped
        }

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID))
        do {
            return CoreAudioTapHandle(
                id: tapID,
                uuid: description.uuid,
                format: try inputFormat(for: tapID)
            )
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    public func destroyProcessTap(_ tap: CoreAudioTapHandle) {
        _ = AudioHardwareDestroyProcessTap(tap.id)
    }

    public func createAggregateDevice(for tap: CoreAudioTapHandle) throws -> CoreAudioAggregateDeviceHandle {
        let subTap: [String: Any] = [
            kAudioSubTapUIDKey: tap.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mimi for Mac Tap Device",
            kAudioAggregateDeviceUIDKey: "com.mimi-for-mac.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [subTap]
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID))
        return CoreAudioAggregateDeviceHandle(id: deviceID)
    }

    public func destroyAggregateDevice(_ device: CoreAudioAggregateDeviceHandle) {
        _ = AudioHardwareDestroyAggregateDevice(device.id)
    }

    public func createIOProc(
        for device: CoreAudioAggregateDeviceHandle,
        format: CoreAudioInputFormat,
        onInput: @escaping @Sendable (CoreAudioInputBuffer) -> Void
    ) throws -> CoreAudioIOProcHandle {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            device.id,
            callbackQueue
        ) { _, inputData, _, _, _ in
            guard let converted = CoreAudioAudioBufferConverter.convert(inputData, format: format) else { return }
            onInput(converted)
        }
        try check(status)
        guard let ioProcID else { throw CaptureError.backendUnavailable("Core Audio did not create an IOProc.") }
        lock.lock()
        let token = nextToken
        nextToken &+= 1
        ioProcIDs[token] = ioProcID
        lock.unlock()
        return CoreAudioIOProcHandle(token: token)
    }

    public func destroyIOProc(_ proc: CoreAudioIOProcHandle, from device: CoreAudioAggregateDeviceHandle) {
        guard let ioProcID = takeIOProc(proc) else { return }
        _ = AudioDeviceDestroyIOProcID(device.id, ioProcID)
    }

    public func startDevice(_ device: CoreAudioAggregateDeviceHandle, proc: CoreAudioIOProcHandle) throws {
        guard let ioProcID = ioProc(proc) else {
            throw CaptureError.backendUnavailable("Core Audio IOProc is unavailable.")
        }
        try check(AudioDeviceStart(device.id, ioProcID))
    }

    public func stopDevice(_ device: CoreAudioAggregateDeviceHandle, proc: CoreAudioIOProcHandle) {
        guard let ioProcID = ioProc(proc) else { return }
        _ = AudioDeviceStop(device.id, ioProcID)
    }

    private func ioProc(_ handle: CoreAudioIOProcHandle) -> AudioDeviceIOProcID? {
        lock.lock(); defer { lock.unlock() }
        return ioProcIDs[handle.token]
    }

    private func takeIOProc(_ handle: CoreAudioIOProcHandle) -> AudioDeviceIOProcID? {
        lock.lock(); defer { lock.unlock() }
        return ioProcIDs.removeValue(forKey: handle.token)
    }

    private func inputFormat(for tapID: AudioObjectID) throws -> CoreAudioInputFormat {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
        let encoding: CoreAudioSampleEncoding
        if format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
           format.mBitsPerChannel == 32 {
            encoding = .float32
        } else if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                  format.mBitsPerChannel == 16 {
            encoding = .signedInt16
        } else {
            throw CaptureError.unsupportedFormat(
                "Process Tap must provide Float32 or signed Int16 PCM."
            )
        }
        return CoreAudioInputFormat(
            sampleRate: format.mSampleRate,
            channels: Int(format.mChannelsPerFrame),
            encoding: encoding,
            interleaved: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.system(status) }
    }
}

/// macOS 14.2+ Core Audio Process Tap with a private aggregate device and IOProc drain.
@available(macOS 14.2, *)
public final class CoreAudioProcessTapBackend: CaptureBackend, @unchecked Sendable {
    private struct Resources {
        let tap: CoreAudioTapHandle
        let device: CoreAudioAggregateDeviceHandle
        let ioProc: CoreAudioIOProcHandle
        let started: Bool
    }

    public let backendName = "Core Audio Process Tap"
    public let exclusionConfiguration: ProcessExclusionConfiguration
    public let resolver: any ProcessObjectResolving

    private let api: any CoreAudioProcessTapAPI
    private let lock = NSLock()
    private var resources: Resources?
    private var starting = false

    public init(
        exclusionConfiguration: ProcessExclusionConfiguration = .currentProcess(),
        resolver: any ProcessObjectResolving = CoreAudioProcessObjectResolver(),
        api: (any CoreAudioProcessTapAPI)? = nil
    ) {
        self.exclusionConfiguration = exclusionConfiguration
        self.resolver = resolver
        self.api = api ?? SystemCoreAudioProcessTapAPI()
    }

    deinit { cleanup(extractResources()) }

    public func start(
        source: AudioSource,
        onEvent: @escaping @Sendable (CaptureEvent) -> Void
    ) async throws {
        guard beginStart() else { throw CaptureError.alreadyRunning }

        var tap: CoreAudioTapHandle?
        var device: CoreAudioAggregateDeviceHandle?
        var ioProc: CoreAudioIOProcHandle?
        do {
            tap = try api.createProcessTap(try tapConfiguration(for: source))
            device = try api.createAggregateDevice(for: tap!)
            ioProc = try api.createIOProc(for: device!, format: tap!.format) { input in
                onEvent(.audio(AudioSampleBuffer(
                    sampleRate: input.sampleRate,
                    channels: input.channels,
                    samples: input.samples
                )))
            }
            try api.startDevice(device!, proc: ioProc!)
            let completed = Resources(tap: tap!, device: device!, ioProc: ioProc!, started: true)
            finishStart(with: completed)
            onEvent(.started)
        } catch {
            if let ioProc, let device { api.destroyIOProc(ioProc, from: device) }
            if let device { api.destroyAggregateDevice(device) }
            if let tap { api.destroyProcessTap(tap) }
            cancelStart()
            throw error
        }
    }

    public func stop() async {
        cleanup(extractResources())
    }

    private func tapConfiguration(for source: AudioSource) throws -> CoreAudioTapConfiguration {
        switch source.kind {
        case .application:
            guard let processID = source.processID else {
                throw CaptureError.backendUnavailable("Application source has no process identifier.")
            }
            return CoreAudioTapConfiguration(
                includedProcessObjectIDs: try resolver.processObjectIDs(forApplicationProcessID: processID),
                muteBehavior: .mutedWhenTapped
            )
        case .display, .system:
            return CoreAudioTapConfiguration(
                excludedProcessObjectIDs: try exclusionConfiguration.resolve(using: resolver).processObjectIDs,
                muteBehavior: .mutedWhenTapped
            )
        case .window:
            throw CaptureError.backendUnavailable("Core Audio cannot isolate one application window.")
        }
    }

    private func extractResources() -> Resources? {
        lock.lock(); defer { lock.unlock() }
        let current = resources
        resources = nil
        return current
    }

    private func beginStart() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard resources == nil, !starting else { return false }
        starting = true
        return true
    }

    private func finishStart(with completed: Resources) {
        lock.lock(); defer { lock.unlock() }
        resources = completed
        starting = false
    }

    private func cancelStart() {
        lock.lock(); defer { lock.unlock() }
        starting = false
    }

    private func cleanup(_ current: Resources?) {
        guard let current else { return }
        if current.started { api.stopDevice(current.device, proc: current.ioProc) }
        api.destroyIOProc(current.ioProc, from: current.device)
        api.destroyAggregateDevice(current.device)
        api.destroyProcessTap(current.tap)
    }
}
