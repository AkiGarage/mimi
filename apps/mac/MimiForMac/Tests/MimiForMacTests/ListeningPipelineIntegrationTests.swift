import Foundation
import XCTest
@testable import MimiForMac

final class ListeningPipelineIntegrationTests: XCTestCase {
    func testCancelledRestartDoesNotStartAReplacementSession() async throws {
        let capture = PipelineFakeCapture()
        let first = PipelineFakeTransport()
        let second = PipelineFakeTransport()
        let transports = PipelineTransportSequence([first, second])
        let player = PipelineFakePlayer()
        let pipeline = ListeningPipelineCoordinator(
            capture: capture,
            sessionFactory: { _, handler in
                GeminiLiveTranslationSession(
                    credential: GeminiCredential("test-only-credential"),
                    transport: transports.next(),
                    onEvent: handler
                )
            },
            player: player
        )
        let source = AudioSource.process(
            id: "pid:42",
            name: "QuickTime Player",
            processID: 42
        )

        _ = try await pipeline.start(source: source)
        let restart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.restartSource(source)
        }

        do {
            _ = try await restart.value
            XCTFail("A cancelled restart must not start a replacement session")
        } catch is CancellationError {
            // Expected: Stop remains the final privacy boundary.
        }
        XCTAssertEqual(capture.startedSources(), [source])
        XCTAssertEqual(first.closeCount, 1)
        XCTAssertEqual(second.connectCount, 0)
        XCTAssertEqual(player.startCount, 1)
        XCTAssertEqual(player.stopCount, 1)
    }

    func testRestartSourceCreatesFreshGeminiSessionWithoutResettingAutoStopUsage() async throws {
        let capture = PipelineFakeCapture()
        let first = PipelineFakeTransport()
        let second = PipelineFakeTransport()
        let transports = PipelineTransportSequence([first, second])
        let player = PipelineFakePlayer()
        let clock = PipelineTestClock()
        let timer = AutoStopTimer(limitMinutes: 30, clock: clock.now)
        let pipeline = ListeningPipelineCoordinator(
            capture: capture,
            sessionFactory: { _, handler in
                GeminiLiveTranslationSession(
                    credential: GeminiCredential("test-only-credential"),
                    transport: transports.next(),
                    onEvent: handler
                )
            },
            player: player,
            autoStopTimer: timer,
            paidUsageGuard: PaidUsageGuard(
                mode: .free,
                monotonicClock: clock.now,
                wallClock: { Date(timeIntervalSince1970: 0) }
            )
        )
        let quickTime = AudioSource.process(
            id: "pid:42",
            name: "QuickTime Player",
            processID: 42
        )

        _ = try await pipeline.start(source: quickTime)
        first.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        capture.emit(.audio(AudioSampleBuffer(
            sampleRate: 16_000,
            channels: 1,
            samples: Array(repeating: 0.25, count: 1_601)
        )))
        try await waitUntil { first.audioMessageCount == 1 }
        clock.advance(by: 5)

        _ = try await pipeline.restartSource(quickTime)

        XCTAssertEqual(capture.startedSources(), [quickTime, quickTime])
        XCTAssertEqual(first.closeCount, 1)
        XCTAssertEqual(second.connectCount, 1)
        XCTAssertEqual(player.startCount, 2)
        XCTAssertEqual(player.stopCount, 1)
        XCTAssertEqual(timer.activeAudioSeconds, 5, accuracy: 0.001)
        await pipeline.stop()
    }

    func testRestartSourceRecoversFromOneTransientConnectionFailure() async throws {
        let capture = PipelineFakeCapture()
        let first = PipelineFakeTransport()
        let transientFailure = PipelineFakeTransport(connectError: GeminiTransportFailure.network)
        let recovered = PipelineFakeTransport()
        let transports = PipelineTransportSequence([first, transientFailure, recovered])
        let player = PipelineFakePlayer()
        let pipeline = ListeningPipelineCoordinator(
            capture: capture,
            sessionFactory: { _, handler in
                GeminiLiveTranslationSession(
                    credential: GeminiCredential("test-only-credential"),
                    transport: transports.next(),
                    onEvent: handler
                )
            },
            player: player
        )
        let source = AudioSource.process(
            id: "pid:84",
            name: "Google Chrome",
            processID: 84
        )

        _ = try await pipeline.start(source: source)
        first.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))

        _ = try await pipeline.restartSource(source)
        recovered.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(recovered.connectCount, 1)
        XCTAssertEqual(capture.startedSources(), [source, source])
        let state = await pipeline.currentState()
        XCTAssertEqual(state, .listening)
        await pipeline.stop()
    }

    func testSwitchSourceStartsNewCaptureWithoutResettingAutoStopUsage() async throws {
        let capture = PipelineFakeCapture()
        let first = PipelineFakeTransport()
        let second = PipelineFakeTransport()
        let transports = PipelineTransportSequence([first, second])
        let player = PipelineFakePlayer()
        let clock = PipelineTestClock()
        let timer = AutoStopTimer(limitMinutes: 30, clock: clock.now)
        let pipeline = ListeningPipelineCoordinator(
            capture: capture,
            sessionFactory: { _, handler in
                GeminiLiveTranslationSession(
                    credential: GeminiCredential("test-only-credential"),
                    transport: transports.next(),
                    onEvent: handler
                )
            },
            player: player,
            autoStopTimer: timer,
            paidUsageGuard: PaidUsageGuard(
                mode: .free,
                monotonicClock: clock.now,
                wallClock: { Date(timeIntervalSince1970: 0) }
            )
        )
        let quickTime = AudioSource.process(id: "pid:42", name: "QuickTime Player", processID: 42)
        let chrome = AudioSource.process(id: "pid:84", name: "Google Chrome", processID: 84)

        _ = try await pipeline.start(source: quickTime)
        first.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        capture.emit(.audio(AudioSampleBuffer(
            sampleRate: 16_000,
            channels: 1,
            samples: Array(repeating: 0.25, count: 1_601)
        )))
        try await waitUntil { first.audioMessageCount == 1 }
        clock.advance(by: 5)

        _ = try await pipeline.switchSource(to: chrome)

        XCTAssertEqual(capture.startedSources(), [quickTime, chrome])
        XCTAssertEqual(timer.activeAudioSeconds, 5, accuracy: 0.001)
        XCTAssertEqual(second.connectCount, 1)
        await pipeline.stop()
    }

    func testSlowTransportUsesBoundedInputQueueAndStopDiscardsPendingAudio() async throws {
        let capture = PipelineFakeCapture()
        let transport = PipelineFakeTransport(blockAudioSends: true)
        let player = PipelineFakePlayer()
        let pipeline = makePipeline(capture: capture, transports: [transport], player: player)

        _ = try await pipeline.start(source: .system)
        transport.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        let buffer = AudioSampleBuffer(
            sampleRate: 16_000,
            channels: 1,
            samples: Array(repeating: 0.25, count: 1_601)
        )
        for _ in 0..<32 { capture.emit(.audio(buffer)) }

        try await waitUntil { transport.blockedAudioSendCount == 1 }
        XCTAssertLessThanOrEqual(pipeline.queuedInputBufferCount, 8)
        await pipeline.stop()
        let countAtStop = transport.audioMessageCount
        capture.emit(.audio(buffer))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(transport.audioMessageCount, countAtStop)
        XCTAssertEqual(pipeline.queuedInputBufferCount, 0)
    }

    func testTransientNetworkReconnectsWithoutTerminalTeardown() async throws {
        let capture = PipelineFakeCapture()
        let first = PipelineFakeTransport()
        let second = PipelineFakeTransport()
        let transports = PipelineTransportSequence([first, second])
        let player = PipelineFakePlayer()
        let pipeline = ListeningPipelineCoordinator(
            capture: capture,
            sessionFactory: { _, handler in
                GeminiLiveTranslationSession(
                    credential: GeminiCredential("test-only-credential"),
                    transportFactory: { _, _ in transports.next() },
                    onEvent: handler
                )
            },
            player: player,
            autoStopTimer: AutoStopTimer(limitMinutes: 30, clock: { 0 }),
            paidUsageGuard: PaidUsageGuard(
                mode: .free,
                monotonicClock: { 0 },
                wallClock: { Date(timeIntervalSince1970: 0) }
            )
        )

        _ = try await pipeline.start(source: .system)
        first.emit(.failed(.network))
        try await waitUntil { second.connectCount == 1 }
        second.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(capture.stopCount, 0)
        let state = await pipeline.currentState()
        XCTAssertEqual(state, .listening)
        await pipeline.stop()
    }

    func testEndToEndCaptureChunkIsSentAs16KMonoPCMAndPlaybackOutputIsRouted() async throws {
        let capture = PipelineFakeCapture()
        let transport = PipelineFakeTransport()
        let player = PipelineFakePlayer()
        let machine = ListeningStateMachine(isSetupComplete: true)
        let pipeline = makePipeline(
            capture: capture,
            transports: [transport],
            player: player,
            stateMachine: machine
        )

        _ = try await pipeline.start(source: .system)
        transport.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        capture.emit(.audio(AudioSampleBuffer(
            sampleRate: 16_000,
            channels: 1,
            // One look-ahead sample is needed by the existing streaming
            // interpolator to produce one complete 100 ms packet.
            samples: Array(repeating: 0.25, count: 1_601)
        )))
        try await waitUntil { transport.audioMessageCount >= 1 }
        XCTAssertEqual(pipeline.captureMetrics.sampleCount, 1_601)
        XCTAssertEqual(pipeline.pendingInputSampleCount, 0)
        let currentState = await pipeline.currentState()
        XCTAssertEqual(currentState, .listening)

        let audio = try XCTUnwrap(transport.sentMessages().last)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: audio) as? [String: Any])
        let realtime = try XCTUnwrap(object["realtimeInput"] as? [String: Any])
        let payload = try XCTUnwrap(realtime["audio"] as? [String: Any])
        XCTAssertEqual(payload["mimeType"] as? String, "audio/pcm;rate=16000")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(payload["data"] as? String))?.count, 3_200)

        transport.emit(.message(Data(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"NBI="}}]}}}"#.utf8)))
        try await waitUntil { player.enqueuedChunks().count == 1 }
        XCTAssertEqual(player.enqueuedChunks().first?.samples, [0x1234])
        XCTAssertFalse(pipeline.hasRawAudioStorage)
        XCTAssertFalse(pipeline.storesRawAudio)
        await pipeline.stop()
    }

    func testCapturedAudioIsMonitoredAndStopsAtPrivacyBoundary() async throws {
        let capture = PipelineFakeCapture()
        let transport = PipelineFakeTransport()
        let player = PipelineFakePlayer()
        let monitor = PipelineFakeSourceMonitor()
        let pipeline = makePipeline(
            capture: capture,
            transports: [transport],
            player: player,
            sourceMonitor: monitor
        )
        let buffer = AudioSampleBuffer(sampleRate: 48_000, channels: 2, samples: [0.25, -0.25])

        _ = try await pipeline.start(source: .system)
        capture.emit(.audio(buffer))
        try await waitUntil { monitor.enqueuedBuffers().count == 1 }
        await pipeline.stop()
        capture.emit(.audio(buffer))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(monitor.enqueuedBuffers(), [buffer])
        XCTAssertEqual(monitor.stopCount, 1)
    }

    func testDuplicateStartAndStopAreIdempotent() async throws {
        let capture = PipelineFakeCapture()
        let transport = PipelineFakeTransport()
        let player = PipelineFakePlayer()
        let pipeline = makePipeline(capture: capture, transports: [transport], player: player)

        let first = try await pipeline.start(source: .system)
        let duplicate = try await pipeline.start(source: .system)
        XCTAssertEqual(first, duplicate)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(transport.connectCount, 1)
        XCTAssertEqual(player.startCount, 1)

        await pipeline.stop()
        await pipeline.stop()
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
        XCTAssertEqual(player.stopCount, 1)
        let state = await pipeline.currentState()
        XCTAssertEqual(state, .ready)
    }

    func testOldGenerationCannotDeliverOutputAfterRestart() async throws {
        let capture = PipelineFakeCapture()
        let firstTransport = PipelineFakeTransport()
        let secondTransport = PipelineFakeTransport()
        let player = PipelineFakePlayer()
        let pipeline = makePipeline(
            capture: capture,
            transports: [firstTransport, secondTransport],
            player: player
        )

        let firstStart = try await pipeline.start(source: .system)
        let firstGeneration = try XCTUnwrap(firstStart)
        await pipeline.stop()
        let secondStart = try await pipeline.start(source: .system)
        let secondGeneration = try XCTUnwrap(secondStart)
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        firstTransport.emit(.message(Data(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"NBI="}}]}}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(player.enqueuedChunks().isEmpty)
    }

    func testTerminalAuthStopsWithoutReconnect() async throws {
        let capture = PipelineFakeCapture()
        let transport = PipelineFakeTransport()
        let player = PipelineFakePlayer()
        let pipeline = makePipeline(capture: capture, transports: [transport], player: player)

        _ = try await pipeline.start(source: .system)
        transport.emit(.message(Data(#"{"error":{"code":401,"status":"UNAUTHENTICATED","message":"bad key"}}"#.utf8)))
        try await waitUntil { capture.stopCount == 1 }
        let state = await pipeline.currentState()
        XCTAssertEqual(state, .failed(.credential))
        XCTAssertEqual(transport.connectCount, 1)
        XCTAssertEqual(transport.closeCount, 1)
    }

    func testSourceEndedStopsAndLeavesSourceReadyForRestart() async throws {
        let capture = PipelineFakeCapture()
        let transport = PipelineFakeTransport()
        let player = PipelineFakePlayer()
        let pipeline = makePipeline(capture: capture, transports: [transport], player: player)

        _ = try await pipeline.start(source: .system)
        capture.emit(.sourceEnded)
        try await waitUntil { capture.stopCount == 1 }
        let state = await pipeline.currentState()
        XCTAssertEqual(state, .sourceEnded)
        XCTAssertNil(pipeline.currentGeneration)
    }

    private func makePipeline(
        capture: PipelineFakeCapture,
        transports: [PipelineFakeTransport],
        player: PipelineFakePlayer,
        stateMachine: ListeningStateMachine = ListeningStateMachine(isSetupComplete: true),
        sourceMonitor: (any SourceAudioMonitoring)? = nil
    ) -> ListeningPipelineCoordinator {
        let sequence = PipelineTransportSequence(transports)
        return ListeningPipelineCoordinator(
            capture: capture,
            sessionFactory: { _, handler in
                GeminiLiveTranslationSession(
                    credential: GeminiCredential("test-only-credential"),
                    transport: sequence.next(),
                    onEvent: handler
                )
            },
            player: player,
            sourceMonitor: sourceMonitor,
            stateMachine: stateMachine,
            autoStopTimer: AutoStopTimer(limitMinutes: 30, clock: { 0 }),
            paidUsageGuard: PaidUsageGuard(mode: .free, monotonicClock: { 0 }, wallClock: { Date(timeIntervalSince1970: 0) })
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("condition timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class PipelineFakeSourceMonitor: SourceAudioMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = [AudioSampleBuffer]()
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws { lock.lock(); startCount += 1; lock.unlock() }
    @discardableResult
    func enqueue(_ buffer: AudioSampleBuffer) -> Bool {
        lock.lock(); buffers.append(buffer); lock.unlock()
        return true
    }
    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
    func enqueuedBuffers() -> [AudioSampleBuffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }
}

private final class PipelineFakeCapture: ListeningCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (CaptureEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var sources = [AudioSource]()

    func start(source: AudioSource, onEvent: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        locked { callback = onEvent; startCount += 1; sources.append(source) }
        onEvent(.started)
    }

    func stop() async {
        locked { stopCount += 1 }
    }

    func emit(_ event: CaptureEvent) {
        lock.lock(); let callback = self.callback; lock.unlock()
        callback?(event)
    }

    func startedSources() -> [AudioSource] { locked { sources } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class PipelineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); value += seconds; lock.unlock()
    }
}

private final class PipelineFakeTransport: GeminiLiveTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (GeminiTransportEvent) -> Void)?
    private var messages = [Data]()
    private let blockAudioSends: Bool
    private let connectError: Error?
    private var blockedAudioContinuation: CheckedContinuation<Void, Never>?
    private(set) var connectCount = 0
    private(set) var closeCount = 0
    private(set) var blockedAudioSendCount = 0

    init(blockAudioSends: Bool = false, connectError: Error? = nil) {
        self.blockAudioSends = blockAudioSends
        self.connectError = connectError
    }

    func connect(onEvent: @escaping @Sendable (GeminiTransportEvent) -> Void) async throws {
        locked { callback = onEvent; connectCount += 1 }
        if let connectError { throw connectError }
    }

    func send(_ message: Data) async throws {
        if blockAudioSends, message.range(of: Data(#""realtimeInput""#.utf8)) != nil {
            await withCheckedContinuation { continuation in
                locked {
                    blockedAudioSendCount += 1
                    blockedAudioContinuation = continuation
                }
            }
        }
        locked { messages.append(message) }
    }

    func close() async {
        let continuation = locked {
            closeCount += 1
            let continuation = blockedAudioContinuation
            blockedAudioContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func emit(_ event: GeminiTransportEvent) {
        lock.lock(); let callback = self.callback; lock.unlock()
        callback?(event)
    }

    func sentMessages() -> [Data] { lock.lock(); defer { lock.unlock() }; return messages }
    var audioMessageCount: Int {
        sentMessages().filter { $0.range(of: Data(#""realtimeInput""#.utf8)) != nil }.count
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class PipelineTransportSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [PipelineFakeTransport]

    init(_ transports: [PipelineFakeTransport]) { self.transports = transports }

    func next() -> PipelineFakeTransport {
        lock.lock(); defer { lock.unlock() }
        return transports.removeFirst()
    }
}

private final class PipelineFakePlayer: ListeningPlayback, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks = [PCMChunk]()
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws { lock.lock(); startCount += 1; lock.unlock() }
    func enqueue(_ chunk: PCMChunk) -> Bool { lock.lock(); chunks.append(chunk); lock.unlock(); return true }
    func flush() {}
    func stop() { lock.lock(); stopCount += 1; lock.unlock() }
    func enqueuedChunks() -> [PCMChunk] { lock.lock(); defer { lock.unlock() }; return chunks }
}
