import Foundation

/// The capture seam owned by the integrated listening pipeline.
///
/// `CaptureSession` is the production adapter. Keeping this boundary small
/// lets lifecycle tests use a fake backend without opening an audio device.
public protocol ListeningCapture: AnyObject, Sendable {
    func start(
        source: AudioSource,
        onEvent: @escaping @Sendable (CaptureEvent) -> Void
    ) async throws
    func stop() async
}

extension CaptureSession: ListeningCapture {}

/// The Japanese playback seam owned by the integrated listening pipeline.
public protocol ListeningPlayback: AnyObject, Sendable {
    func start() throws
    @discardableResult
    func enqueue(_ chunk: PCMChunk) -> Bool
    func flush()
    func stop()
}

extension TranslatedAudioPlayer: ListeningPlayback {}

/// One concrete Gemini session is created for every listening generation.
/// The callback is captured by the coordinator with that generation, so a
/// delayed callback from an old session cannot reach a later one.
public typealias ListeningSessionFactory = @Sendable (
    _ generation: UInt64,
    _ onEvent: @escaping GeminiLiveTranslationSession.EventHandler
) -> GeminiLiveTranslationSession

public typealias ListeningPipelineSessionFactory = ListeningSessionFactory

/// Errors surfaced when the integrated pipeline cannot be started.
public enum ListeningPipelineError: Error, Sendable, Equatable, LocalizedError {
    case setupIncomplete
    case invalidAudioBuffer
    case inputFormatChanged

    public var errorDescription: String? {
        switch self {
        case .setupIncomplete:
            return "Listening setup is incomplete."
        case .invalidAudioBuffer:
            return "The capture audio buffer has an invalid format."
        case .inputFormatChanged:
            return "The capture audio format changed during listening."
        }
    }
}

/// Coordinates one real-time listening session:
///
/// `CaptureSession` -> `StreamingPCMConverter` -> Gemini Live ->
/// `TranslatedAudioPlayer`.
///
/// The coordinator deliberately retains only the converter's short pending
/// window and aggregate capture metrics. It never stores raw audio or a
/// transcript. Every callback is tagged with the coordinator generation.
public final class ListeningPipelineCoordinator: @unchecked Sendable {
    public typealias SessionFactory = ListeningSessionFactory
    private static let maximumQueuedInputBuffers = 8
    private static let maximumTargetRestartAttempts = 3
    private static let targetRestartRetryDelay = Duration.milliseconds(200)

    private let capture: any ListeningCapture
    private let sessionFactory: SessionFactory
    private let player: any ListeningPlayback
    private let sourceMonitor: (any SourceAudioMonitoring)?
    public let stateMachine: ListeningStateMachine
    private let autoStopTimer: AutoStopTimer
    private let paidUsageGuard: PaidUsageGuard
    private let metricsCollector: CaptureMetricsCollector
    private let lock = NSLock()

    private var activeGeneration: UInt64?
    private var session: GeminiLiveTranslationSession?
    private var converter: StreamingPCMConverter?
    private var inputFormat: (sampleRate: Double, channels: Int)?
    private var audioQueue = [AudioSampleBuffer]()
    private var audioTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var teardownInProgress = false
    private var requestedTerminal: ListeningAppState?

    public init(
        capture: any ListeningCapture,
        sessionFactory: @escaping SessionFactory,
        player: any ListeningPlayback,
        sourceMonitor: (any SourceAudioMonitoring)? = nil,
        stateMachine: ListeningStateMachine = ListeningStateMachine(isSetupComplete: true),
        autoStopTimer: AutoStopTimer = AutoStopTimer(),
        paidUsageGuard: PaidUsageGuard = PaidUsageGuard(),
        metricsCollector: CaptureMetricsCollector = CaptureMetricsCollector()
    ) {
        self.capture = capture
        self.sessionFactory = sessionFactory
        self.player = player
        self.sourceMonitor = sourceMonitor
        self.stateMachine = stateMachine
        self.autoStopTimer = autoStopTimer
        self.paidUsageGuard = paidUsageGuard
        self.metricsCollector = metricsCollector
    }

    /// Convenience initializer for the production direct WebSocket session.
    public convenience init(
        capture: any ListeningCapture,
        credential: GeminiCredential,
        targetLanguageCode: String = MimiTargetLanguage.defaultCode,
        transportFactory: @escaping GeminiLiveTranslationSession.TransportFactory,
        player: any ListeningPlayback,
        sourceMonitor: (any SourceAudioMonitoring)? = nil,
        stateMachine: ListeningStateMachine = ListeningStateMachine(isSetupComplete: true),
        autoStopTimer: AutoStopTimer = AutoStopTimer(),
        paidUsageGuard: PaidUsageGuard = PaidUsageGuard(),
        metricsCollector: CaptureMetricsCollector = CaptureMetricsCollector()
    ) {
        self.init(
            capture: capture,
            sessionFactory: { _, handler in
                GeminiLiveTranslationSession(
                    credential: credential,
                    targetLanguageCode: targetLanguageCode,
                    transportFactory: transportFactory,
                    onEvent: handler
                )
            },
            player: player,
            sourceMonitor: sourceMonitor,
            stateMachine: stateMachine,
            autoStopTimer: autoStopTimer,
            paidUsageGuard: paidUsageGuard,
            metricsCollector: metricsCollector
        )
    }

    /// Starts listening for `source` and returns its state-machine generation.
    /// A duplicate start while active returns the existing generation without
    /// starting another capture/session/player.
    @discardableResult
    public func start(source: AudioSource) async throws -> UInt64? {
        try await start(source: source, resetsAutoStopTimer: true)
    }

    /// Restarts capture and Gemini for a new app while preserving the current
    /// logical session's auto-stop and paid-usage accounting.
    @discardableResult
    public func switchSource(to source: AudioSource) async throws -> UInt64? {
        try await restartSource(source)
    }

    /// Creates a fresh Gemini Live session for the current capture target.
    /// This lets voice replication follow a newly playing video without
    /// applying local pitch effects or resetting logical-session accounting.
    @discardableResult
    public func restartSource(_ source: AudioSource) async throws -> UInt64? {
        await stop()
        try Task.checkCancellation()
        var attempt = 1
        while true {
            do {
                return try await start(source: source, resetsAutoStopTimer: false)
            } catch {
                guard Self.isRetryableTargetRestartError(error),
                      attempt < Self.maximumTargetRestartAttempts else {
                    throw error
                }
                attempt += 1
                await stop()
                try Task.checkCancellation()
                try await Task.sleep(for: Self.targetRestartRetryDelay)
            }
        }
    }

    private func start(
        source: AudioSource,
        resetsAutoStopTimer: Bool
    ) async throws -> UInt64? {
        if case .needsSetup = await stateMachine.state {
            throw ListeningPipelineError.setupIncomplete
        }
        await stateMachine.selectSource()
        guard let generation = await stateMachine.start() else {
            return nil
        }

        let shouldInitialize: Bool = locked {
            let shouldInitialize = activeGeneration != generation
            if shouldInitialize {
                activeGeneration = generation
                session = nil
                converter = nil
                inputFormat = nil
                audioQueue.removeAll(keepingCapacity: true)
                audioTask = nil
                teardownTask = nil
                teardownInProgress = false
                requestedTerminal = nil
            }
            return shouldInitialize
        }
        guard shouldInitialize else { return generation }

        let newSession = sessionFactory(generation, { [weak self] event in
            self?.receive(event, generation: generation)
        })
        let installed = locked {
            // A stop may have been requested by a concurrent caller while the
            // factory was constructing the session. Keep the old generation out.
            guard activeGeneration == generation, !teardownInProgress else { return false }
            session = newSession
            return true
        }
        guard installed else { return generation }

        do {
            guard paidUsageGuard.start() else {
                requestTerminal(generation: generation, state: .paidLimitReached)
                return generation
            }
            let timerAllowsStart = resetsAutoStopTimer
                ? autoStopTimer.start()
                : autoStopTimer.resume()
            guard timerAllowsStart else {
                requestTerminal(generation: generation, state: .autoStopReached)
                return generation
            }
            try player.start()
            try sourceMonitor?.start()
            try await newSession.start()
            guard accepts(generation) else { return generation }
            try await capture.start(source: source) { [weak self] event in
                self?.receive(event, generation: generation)
            }
        } catch {
            let failure = listeningFailure(for: error)
            requestTerminal(generation: generation, state: .failed(failure))
            throw error
        }
        return generation
    }

    /// Stops the active generation. The operation is idempotent and waits for
    /// one shared teardown task when duplicate callers race.
    public func stop() async {
        let generation = locked { activeGeneration }
        guard let generation else { return }
        _ = await stateMachine.stop()
        await teardown(generation: generation)
    }

    public var currentGeneration: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return activeGeneration
    }

    public var hasRawAudioStorage: Bool { metricsCollector.hasRawAudioStorage }

    /// Alias used by privacy/acceptance checks.
    public var storesRawAudio: Bool { hasRawAudioStorage }

    public var captureMetrics: CaptureMetrics { metricsCollector.snapshot() }

    public var pendingInputSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return converter?.pendingSampleCount ?? 0
    }

    public var queuedInputBufferCount: Int {
        lock.lock(); defer { lock.unlock() }
        return audioQueue.count
    }

    /// Reads the actor-owned state without exposing its mutable internals.
    public func currentState() async -> ListeningAppState { await stateMachine.state }

    private func receive(_ event: GeminiLiveSessionEvent, generation: UInt64) {
        guard accepts(generation) else { return }
        switch event {
        case .stateChanged(.reconnecting):
            Task { [weak self] in
                guard let self, await self.stateMachine.beginReconnect(generation: generation) else { return }
            }
        case .stateChanged(.translating), .setupCompleted:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.stateMachine.connected(generation: generation)
            }
        case .stateChanged(.failed):
            // The error event carries the category. A failed state without an
            // error is conservatively treated as a network failure.
            requestTerminal(generation: generation, state: .failed(.network))
        case .stateChanged(_), .sessionResumptionUpdated:
            break
        case .audio(let chunk):
            guard chunk.isJapanesePlaybackFormat else {
                requestTerminal(generation: generation, state: .failed(.noAudio))
                return
            }
            _ = player.enqueue(chunk)
        case .reconnectSuggested(timeLeft: _):
            Task { [weak self] in await self?.reconnect(generation: generation) }
        case .error(let error):
            if error.isTerminal {
                requestTerminal(generation: generation, state: .failed(listeningFailure(for: error)))
            } else if error.category == .transientNetwork {
                Task { [weak self] in await self?.reconnect(generation: generation) }
            }
        }
    }

    private func receive(_ event: CaptureEvent, generation: UInt64) {
        guard accepts(generation) else { return }
        switch event {
        case .audio(let buffer):
            _ = sourceMonitor?.enqueue(buffer)
            metricsCollector.ingest(buffer)
            enqueueAudio(buffer, generation: generation)
        case .sourceEnded:
            requestTerminal(generation: generation, state: .sourceEnded)
        case .permissionDenied:
            requestTerminal(generation: generation, state: .failed(.permission))
        case .failed(let error):
            requestTerminal(generation: generation, state: .failed(listeningFailure(for: error)))
        case .started, .metrics, .stopped:
            break
        }
    }

    private func enqueueAudio(_ buffer: AudioSampleBuffer, generation: UInt64) {
        lock.lock()
        guard activeGeneration == generation, !teardownInProgress else {
            lock.unlock()
            return
        }
        if audioQueue.count == Self.maximumQueuedInputBuffers {
            audioQueue.removeFirst()
        }
        audioQueue.append(buffer)
        if audioTask == nil {
            audioTask = Task.detached { [weak self] in
                await self?.drainAudioQueue(generation: generation)
            }
        }
        lock.unlock()
    }

    private func drainAudioQueue(generation: UInt64) async {
        while !Task.isCancelled {
            let next: AudioSampleBuffer? = locked {
                guard activeGeneration == generation, !teardownInProgress else {
                    audioQueue.removeAll(keepingCapacity: true)
                    audioTask = nil
                    return nil
                }
                guard !audioQueue.isEmpty else {
                    audioTask = nil
                    return nil
                }
                return audioQueue.removeFirst()
            }
            guard let next else { return }
            await processAudio(next, generation: generation)
        }
    }

    private func processAudio(_ buffer: AudioSampleBuffer, generation: UInt64) async {
        guard !Task.isCancelled, accepts(generation) else { return }
        guard buffer.channels > 0,
              buffer.sampleRate.isFinite,
              buffer.sampleRate > 0,
              buffer.samples.count.isMultiple(of: buffer.channels) else {
            requestTerminal(generation: generation, state: .failed(.noAudio))
            return
        }

        let chunks: [PCMChunk]
        do {
            let result: [PCMChunk]? = try locked {
                guard activeGeneration == generation else { return nil }
                if let inputFormat {
                    guard inputFormat.sampleRate == buffer.sampleRate,
                          inputFormat.channels == buffer.channels else {
                        throw ListeningPipelineError.inputFormatChanged
                    }
                } else {
                    inputFormat = (buffer.sampleRate, buffer.channels)
                    converter = try StreamingPCMConverter(
                        inputSampleRate: buffer.sampleRate,
                        inputChannels: buffer.channels,
                        outputSampleRate: GeminiLiveTranslationSession.inputSampleRate,
                        chunkDuration: 0.1
                    )
                }
                return converter?.append(buffer.samples) ?? []
            }
            guard let result else { return }
            chunks = result
        } catch {
            requestTerminal(generation: generation, state: .failed(.noAudio))
            return
        }

        guard !chunks.isEmpty else { return }
        guard autoStopTimer.beginAudioSending(), paidUsageGuard.beginAudioSending() else {
            requestTerminal(
                generation: generation,
                state: paidUsageGuard.shouldStop ? .paidLimitReached : .autoStopReached
            )
            return
        }
        for chunk in chunks {
            guard !Task.isCancelled, accepts(generation) else { return }
            do {
                guard let session = currentSession(for: generation) else { return }
                _ = try await session.sendAudio(chunk)
            } catch {
                // Do not await teardown from this task: teardown waits this
                // task, and doing so would deadlock on a send failure.
                requestTerminal(generation: generation, state: .failed(listeningFailure(for: error)))
                return
            }
            if autoStopTimer.shouldStop || paidUsageGuard.shouldStop {
                requestTerminal(
                    generation: generation,
                    state: paidUsageGuard.shouldStop ? .paidLimitReached : .autoStopReached
                )
                return
            }
        }
    }

    private func reconnect(generation: UInt64) async {
        guard accepts(generation) else { return }
        _ = await stateMachine.beginReconnect(generation: generation)
        guard let session = currentSession(for: generation) else { return }
        do {
            try await session.reconnect()
        } catch let error as GeminiLiveSessionError {
            if error.isTerminal {
                requestTerminal(generation: generation, state: .failed(listeningFailure(for: error)))
            }
        } catch {
            requestTerminal(generation: generation, state: .failed(.network))
        }
    }

    private func requestTerminal(generation: UInt64, state: ListeningAppState) {
        let effectiveState: ListeningAppState
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        if requestedTerminal == nil { requestedTerminal = state }
        effectiveState = requestedTerminal ?? state
        lock.unlock()
        Task { [weak self] in
            guard let self else { return }
            await self.stateMachine.terminate(generation: generation, as: effectiveState)
            await self.teardown(generation: generation)
        }
    }

    private func teardown(generation: UInt64) async {
        let operation: Task<Void, Never>? = locked {
            guard activeGeneration == generation else { return teardownTask }
            if let teardownTask { return teardownTask }
            teardownInProgress = true
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.runTeardown(generation: generation)
            }
            teardownTask = task
            return task
        }
        await operation?.value
    }

    private func runTeardown(generation: UInt64) async {
        sourceMonitor?.stop()
        await capture.stop()
        let (pendingAudioTask, activeSession) = locked {
            audioQueue.removeAll(keepingCapacity: false)
            converter = nil
            return (audioTask, session)
        }
        pendingAudioTask?.cancel()
        // Close the transport before awaiting an in-flight sender. This makes
        // Stop a privacy boundary: no queued or converter-tail audio is sent
        // after the user requests teardown.
        await activeSession?.stop()
        await pendingAudioTask?.value

        autoStopTimer.endAudioSending()
        paidUsageGuard.endAudioSending()
        player.flush()
        player.stop()

        let terminal: ListeningAppState? = locked {
            let terminal = requestedTerminal
            if activeGeneration == generation {
                activeGeneration = nil
                session = nil
                converter = nil
                inputFormat = nil
                audioQueue.removeAll(keepingCapacity: false)
                audioTask = nil
                teardownInProgress = false
            }
            return terminal
        }

        if let terminal {
            await stateMachine.terminate(generation: generation, as: terminal)
        } else {
            await stateMachine.stopped(generation: generation)
        }
    }

    private func accepts(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeGeneration == generation && !teardownInProgress
    }

    private func currentSession(for generation: UInt64) -> GeminiLiveTranslationSession? {
        lock.lock(); defer { lock.unlock() }
        return activeGeneration == generation ? session : nil
    }

    private static func isRetryableTargetRestartError(_ error: Error) -> Bool {
        if let error = error as? GeminiLiveSessionError {
            return error.category == .transientNetwork
        }
        if let error = error as? GeminiTransportFailure {
            switch error {
            case .notConnected, .network: return true
            case .cancelled: return false
            }
        }
        return false
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public typealias ListeningPipeline = ListeningPipelineCoordinator
public typealias MacListeningCoordinator = ListeningPipelineCoordinator
public typealias ListeningCoordinator = ListeningPipelineCoordinator

private func listeningFailure(for error: Error) -> ListeningFailure {
    if let error = error as? CaptureError {
        switch error {
        case .permissionDenied: return .permission
        case .sourceEnded: return .noAudio
        default: return .unknown
        }
    }
    if let error = error as? GeminiLiveSessionError {
        switch error.category {
        case .authentication: return .credential
        case .quota: return .quota
        case .billing: return .billing
        case .transientNetwork: return .network
        case .invalidAudio, .protocolViolation: return .noAudio
        default: return .unknown
        }
    }
    if let error = error as? ListeningPipelineError {
        switch error {
        case .invalidAudioBuffer, .inputFormatChanged: return .noAudio
        case .setupIncomplete: return .credential
        }
    }
    return .unknown
}
