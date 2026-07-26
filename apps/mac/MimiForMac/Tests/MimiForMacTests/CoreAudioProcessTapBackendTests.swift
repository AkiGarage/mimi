import CoreAudio
import XCTest
@testable import MimiForMac

@available(macOS 14.2, *)
final class CoreAudioProcessTapBackendTests: XCTestCase {
    func testProcessFamilyContainsDirectAndNestedAudioHelpersOnly() {
        let parents: [Int32: Int32] = [1_719: 42, 1_800: 1_719, 9_001: 7]
        let parentOf: (Int32) -> Int32? = { parents[$0] }

        XCTAssertTrue(CoreAudioProcessFamily.contains(42, root: 42, parentOf: parentOf))
        XCTAssertTrue(CoreAudioProcessFamily.contains(1_719, root: 42, parentOf: parentOf))
        XCTAssertTrue(CoreAudioProcessFamily.contains(1_800, root: 42, parentOf: parentOf))
        XCTAssertFalse(CoreAudioProcessFamily.contains(9_001, root: 42, parentOf: parentOf))
    }

    func testProcessFamilyStopsWhenParentChainCycles() {
        let parents: [Int32: Int32] = [8: 9, 9: 8]
        XCTAssertFalse(CoreAudioProcessFamily.contains(8, root: 42) { parents[$0] })
    }

    func testApplicationTapUsesFailSafeMuteWhileBeingRead() async throws {
        let api = FakeProcessTapAPI()
        let backend = CoreAudioProcessTapBackend(
            exclusionConfiguration: ProcessExclusionConfiguration(selfProcessID: 1),
            resolver: FakeProcessResolver(),
            api: api
        )
        let source = AudioSource.process(id: "pid:42", name: "Safari", processID: 42)

        try await backend.start(source: source) { _ in }

        XCTAssertEqual(api.configurations, [CoreAudioTapConfiguration(
            includedProcessObjectIDs: [1_042],
            muteBehavior: .mutedWhenTapped
        )])
        await backend.stop()
    }

    func testApplicationTapIncludesAudioProcessesInApplicationFamily() async throws {
        let api = FakeProcessTapAPI()
        let backend = CoreAudioProcessTapBackend(
            exclusionConfiguration: ProcessExclusionConfiguration(selfProcessID: 1),
            resolver: FamilyProcessResolver(),
            api: api
        )
        let source = AudioSource.process(id: "pid:42", name: "Chrome", processID: 42)

        try await backend.start(source: source) { _ in }

        XCTAssertEqual(api.configurations, [CoreAudioTapConfiguration(
            includedProcessObjectIDs: [1_042, 1_719],
            muteBehavior: .mutedWhenTapped
        )])
        await backend.stop()
    }

    func testStartFailureRollsBackEveryCreatedResourceInReverseOrder() async throws {
        let api = FakeProcessTapAPI(failAt: .startDevice)
        let backend = CoreAudioProcessTapBackend(
            exclusionConfiguration: ProcessExclusionConfiguration(selfProcessID: 1),
            resolver: FakeProcessResolver(),
            api: api
        )

        do {
            try await backend.start(source: .system) { _ in }
            XCTFail("expected start to fail")
        } catch {
            XCTAssertTrue(error is CaptureError)
        }

        XCTAssertEqual(api.operations, [
            "createTap",
            "createAggregate",
            "createIOProc",
            "startDevice",
            "destroyIOProc",
            "destroyAggregate",
            "destroyTap"
        ])
        await backend.stop()
        XCTAssertEqual(api.operations.count, 7)
    }

    func testStopIsIdempotentAndDestroysStartedResourcesInReverseOrder() async throws {
        let api = FakeProcessTapAPI()
        let backend = CoreAudioProcessTapBackend(
            exclusionConfiguration: ProcessExclusionConfiguration(selfProcessID: 1),
            resolver: FakeProcessResolver(),
            api: api
        )
        try await backend.start(source: .system) { _ in }

        await backend.stop()
        await backend.stop()

        XCTAssertEqual(api.operations, [
            "createTap",
            "createAggregate",
            "createIOProc",
            "startDevice",
            "stopDevice",
            "destroyIOProc",
            "destroyAggregate",
            "destroyTap"
        ])
    }

    func testInputCallbackConvertsToAudioEvent() async throws {
        let api = FakeProcessTapAPI()
        let backend = CoreAudioProcessTapBackend(
            exclusionConfiguration: ProcessExclusionConfiguration(selfProcessID: 1),
            resolver: FakeProcessResolver(),
            api: api
        )
        let expectation = expectation(description: "audio callback")
        let received = LockedAudioBuffer()
        try await backend.start(source: .system) { event in
            if case .audio(let buffer) = event {
                received.set(buffer)
                expectation.fulfill()
            }
        }

        api.emitInput(CoreAudioInputBuffer(sampleRate: 48_000, channels: 1, samples: [0.25, -0.5]))
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(received.value, AudioSampleBuffer(sampleRate: 48_000, channels: 1, samples: [0.25, -0.5]))
        await backend.stop()
    }

    func testAudioBufferListConverterHandlesFloatInterleavedSamples() {
        let values: [Float] = [0.25, -0.5, 0.75, -1]
        let byteCount = values.count * MemoryLayout<Float>.size
        let list = AudioBufferList.allocate(maximumBuffers: 1)
        defer { list.unsafeMutablePointer.deallocate() }
        let data = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Float>.alignment)
        defer { data.deallocate() }
        data.copyMemory(from: values, byteCount: byteCount)
        list[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(byteCount),
            mData: data
        )

        let format = CoreAudioInputFormat(
            sampleRate: 48_000,
            channels: 1,
            encoding: .float32,
            interleaved: true
        )
        let converted = CoreAudioAudioBufferConverter.convert(
            list.unsafePointer,
            format: format
        )
        XCTAssertEqual(converted, CoreAudioInputBuffer(sampleRate: 48_000, channels: 1, samples: values))
    }
}

private final class LockedAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AudioSampleBuffer?

    var value: AudioSampleBuffer? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ value: AudioSampleBuffer) {
        lock.lock(); storage = value; lock.unlock()
    }
}

@available(macOS 14.2, *)
private final class FakeProcessTapAPI: CoreAudioProcessTapAPI, @unchecked Sendable {
    enum FailurePoint { case createTap, createAggregate, createIOProc, startDevice }

    let failAt: FailurePoint?
    private(set) var operations = [String]()
    private(set) var configurations = [CoreAudioTapConfiguration]()
    private var inputCallback: (@Sendable (CoreAudioInputBuffer) -> Void)?

    init(failAt: FailurePoint? = nil) { self.failAt = failAt }

    func createProcessTap(_ configuration: CoreAudioTapConfiguration) throws -> CoreAudioTapHandle {
        operations.append("createTap")
        configurations.append(configuration)
        if failAt == .createTap { throw CaptureError.system(-1) }
        return CoreAudioTapHandle(id: 100, uuid: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    }

    func destroyProcessTap(_ tap: CoreAudioTapHandle) { operations.append("destroyTap") }

    func createAggregateDevice(for tap: CoreAudioTapHandle) throws -> CoreAudioAggregateDeviceHandle {
        operations.append("createAggregate")
        if failAt == .createAggregate { throw CaptureError.system(-2) }
        return CoreAudioAggregateDeviceHandle(id: 200)
    }

    func destroyAggregateDevice(_ device: CoreAudioAggregateDeviceHandle) { operations.append("destroyAggregate") }

    func createIOProc(
        for device: CoreAudioAggregateDeviceHandle,
        format: CoreAudioInputFormat,
        onInput: @escaping @Sendable (CoreAudioInputBuffer) -> Void
    ) throws -> CoreAudioIOProcHandle {
        operations.append("createIOProc")
        if failAt == .createIOProc { throw CaptureError.system(-3) }
        inputCallback = onInput
        return CoreAudioIOProcHandle(token: 300)
    }

    func destroyIOProc(_ proc: CoreAudioIOProcHandle, from device: CoreAudioAggregateDeviceHandle) {
        operations.append("destroyIOProc")
        inputCallback = nil
    }

    func startDevice(_ device: CoreAudioAggregateDeviceHandle, proc: CoreAudioIOProcHandle) throws {
        operations.append("startDevice")
        if failAt == .startDevice { throw CaptureError.system(-4) }
    }

    func stopDevice(_ device: CoreAudioAggregateDeviceHandle, proc: CoreAudioIOProcHandle) {
        operations.append("stopDevice")
    }

    func emitInput(_ input: CoreAudioInputBuffer) { inputCallback?(input) }
}

@available(macOS 14.2, *)
private struct FakeProcessResolver: ProcessObjectResolving {
    func processObjectID(for processID: Int32) throws -> UInt32 { UInt32(processID) + 1000 }
}

@available(macOS 14.2, *)
private struct FamilyProcessResolver: ProcessObjectResolving {
    func processObjectID(for processID: Int32) throws -> UInt32 { UInt32(processID) + 1000 }

    func processObjectIDs(forApplicationProcessID processID: Int32) throws -> [UInt32] {
        [UInt32(processID) + 1000, 1_719]
    }
}
