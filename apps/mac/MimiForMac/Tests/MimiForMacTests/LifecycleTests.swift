import XCTest
@testable import MimiForMac

final class LifecycleTests: XCTestCase {
    func testStopWaitsForConcurrentStartAndLeavesBackendInactive() async throws {
        let backend = DelayedCaptureBackend()
        let session = CaptureSession(backend: backend)

        let start = Task {
            try await session.start(source: .process(id: "source", name: "Source", processID: 9)) { _ in }
        }
        try await Task.sleep(for: .milliseconds(20))
        let stop = Task { await session.stop() }
        try await Task.sleep(for: .milliseconds(20))
        backend.completeStart()

        try await start.value
        await stop.value
        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertFalse(backend.isActive)
        XCTAssertEqual(session.currentState, .ended)
    }

    func testStopIsIdempotentAndTerminalEventIsDeliveredOnce() async throws {
        let backend = FakeCaptureBackend()
        let session = CaptureSession(backend: backend)
        let recorder = EventRecorder()

        try await session.start(source: .process(id: "source", name: "Source", processID: 9)) { event in
            recorder.append(event)
        }
        await session.stop()
        await session.stop()

        XCTAssertEqual(backend.startCount, 1)
        XCTAssertEqual(backend.stopCount, 1)
        let events = recorder.snapshot()
        XCTAssertEqual(events.filter { $0 == .sourceEnded }.count, 0)
        XCTAssertEqual(events.filter { $0 == .stopped }.count, 1)
    }

    func testSourceEndedStopsBackendAndDoesNotEmitDuplicateTerminalEvents() async throws {
        let backend = FakeCaptureBackend()
        let session = CaptureSession(backend: backend)
        let recorder = EventRecorder()
        try await session.start(source: .process(id: "source", name: "Source", processID: 9)) { event in
            recorder.append(event)
        }

        backend.emit(.sourceEnded)
        backend.emit(.sourceEnded)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(recorder.snapshot().filter { $0 == .sourceEnded }.count, 1)
    }

    func testPermissionErrorIsForwardedAndStopRemainsSafe() async throws {
        let backend = FakeCaptureBackend()
        let session = CaptureSession(backend: backend)
        let recorder = EventRecorder()
        try await session.start(source: .process(id: "source", name: "Source", processID: 9)) { event in
            recorder.append(event)
        }

        backend.emit(.permissionDenied)
        try await Task.sleep(for: .milliseconds(20))
        await session.stop()

        XCTAssertEqual(recorder.snapshot().filter { $0 == .permissionDenied }.count, 1)
        XCTAssertEqual(backend.stopCount, 1)
    }
}

private final class DelayedCaptureBackend: CaptureBackend, @unchecked Sendable {
    let backendName = "delayed"
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isActive = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func start(source: AudioSource, onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        withLock { startCount += 1 }
        await withCheckedContinuation { continuation in
            withLock { self.continuation = continuation }
        }
        withLock { isActive = true }
        onEvent(.started)
    }

    func stop() async {
        withLock {
            stopCount += 1
            isActive = false
        }
    }

    func completeStart() {
        let continuation = withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class FakeCaptureBackend: CaptureBackend, @unchecked Sendable {
    let backendName = "fake"
    private let lock = NSLock()
    private var callback: (@Sendable (CaptureEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func start(source: AudioSource, onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        withLock {
            callback = onEvent
            startCount += 1
        }
        onEvent(.started)
    }

    func stop() async {
        withLock { stopCount += 1 }
    }

    func emit(_ event: CaptureEvent) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(event)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [CaptureEvent]()

    func append(_ event: CaptureEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func snapshot() -> [CaptureEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
