import AVFoundation
import Foundation

/// Rendering seam used by `TranslatedAudioPlayer`. The queue/lifecycle can be
/// tested without an audio device; the production implementation below uses
/// AVAudioEngine and AVAudioPlayerNode.
public protocol PCMPlaybackRenderer: AnyObject, Sendable {
    func start() throws
    func stop()
    func clearScheduled()
    func setVolume(_ volume: Float)
    func setPlaybackRate(_ rate: Double)
    func schedule(_ chunk: PCMChunk, completion: @escaping @Sendable () -> Void)
}

/// A single native macOS output path for Gemini's Japanese 24 kHz PCM.
///
/// A bounded look-ahead is handed to the renderer so adjacent PCM chunks are
/// already scheduled and play without callback-sized gaps. Additional output
/// remains in `PCMPlaybackQueue`, so AVAudioPlayerNode cannot become an
/// unbounded latency reservoir. Completion callbacks are generation-tagged so
/// a callback from a stopped session cannot affect a later session.
public final class TranslatedAudioPlayer: @unchecked Sendable {
    private let renderer: any PCMPlaybackRenderer
    private let playbackRateProvider: any PlaybackRateProvider
    private let lock = NSLock()
    private var queue: PCMPlaybackQueue
    private var tempoController: TranslationTempoController
    private let initialBufferingDuration: TimeInterval
    private let maxScheduledDuration: TimeInterval
    private var running = false
    private var scheduledChunkCount = 0
    private var scheduledDuration: TimeInterval = 0
    private var isScheduling = false
    private var hasStartedPlayback = false
    private var generation: UInt64 = 0
    private var currentVolume: Float = 1

    public init(
        renderer: any PCMPlaybackRenderer = AVAudioEnginePlaybackRenderer(),
        playbackRateProvider: any PlaybackRateProvider = ManualPlaybackRateProvider(),
        maxQueueDuration: TimeInterval = 0.5,
        initialBufferingDuration: TimeInterval = 0.02
    ) {
        self.renderer = renderer
        self.playbackRateProvider = playbackRateProvider
        self.queue = PCMPlaybackQueue(maxDuration: maxQueueDuration)
        self.tempoController = TranslationTempoController(
            initialBaseRate: playbackRateProvider.playbackRate
        )
        self.initialBufferingDuration = max(0, initialBufferingDuration)
        self.maxScheduledDuration = max(0, maxQueueDuration)
    }

    public var volume: Float {
        get {
            lock.lock(); defer { lock.unlock() }
            return currentVolume
        }
        set {
            let clamped = min(1, max(0, newValue))
            lock.lock()
            currentVolume = clamped
            lock.unlock()
            renderer.setVolume(clamped)
        }
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public var queuedDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return queue.queuedDuration
    }

    public var droppedChunkCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.droppedChunkCount
    }

    public func start() throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        let nextGeneration = generation &+ 1
        generation = nextGeneration
        let initialRate = tempoController.reset(baseRate: playbackRateProvider.playbackRate)
        lock.unlock()

        do {
            try renderer.start()
            lock.lock()
            let volume = currentVolume
            running = true
            hasStartedPlayback = false
            renderer.setVolume(volume)
            renderer.setPlaybackRate(initialRate)
            lock.unlock()
            scheduleNextIfReady()
        } catch {
            lock.lock()
            generation = nextGeneration &+ 1
            lock.unlock()
            throw error
        }
    }

    public func enqueue(_ chunk: PCMChunk) -> Bool {
        guard !chunk.samples.isEmpty else { return false }
        lock.lock()
        guard running else {
            lock.unlock()
            return false
        }
        let result = queue.enqueue(chunk)
        let accepted = result.kind == .accepted || result.kind == .acceptedAfterDroppingOldest
        lock.unlock()
        guard accepted else { return false }
        refreshPlaybackRate()
        scheduleNextIfReady()
        return true
    }

    public func enqueue(_ data: Data) throws {
        let chunk = try PCMPlaybackDataDecoder.decode(data)
        _ = enqueue(chunk)
    }

    /// Flushes both queued and currently scheduled audio, but keeps the engine
    /// running. Calling it repeatedly is safe.
    public func flush() {
        lock.lock()
        queue.flush()
        generation &+= 1
        scheduledChunkCount = 0
        scheduledDuration = 0
        hasStartedPlayback = false
        let shouldResume = running
        let flushGeneration = generation
        tempoController.reset(baseRate: playbackRateProvider.playbackRate)
        lock.unlock()

        renderer.clearScheduled()
        lock.lock()
        if shouldResume, running, generation == flushGeneration {
            // A manual update may have arrived while scheduled buffers were
            // cleared. Apply the newest controller value, not a stale base.
            renderer.setPlaybackRate(tempoController.currentRate)
        }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        guard running || scheduledChunkCount > 0 || queue.queuedChunkCount > 0 else {
            lock.unlock()
            return
        }
        running = false
        scheduledChunkCount = 0
        scheduledDuration = 0
        hasStartedPlayback = false
        generation &+= 1
        queue.flush()
        lock.unlock()
        renderer.stop()
    }

    /// Re-evaluates the renderer immediately after a manual source-speed
    /// change. The running Gemini/capture session is intentionally untouched.
    public func refreshPlaybackRate() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        let rate = tempoController.update(
            baseRate: playbackRateProvider.playbackRate,
            bufferedDuration: queue.queuedDuration + scheduledDuration
        )
        renderer.setPlaybackRate(rate)
        lock.unlock()
    }

    private func scheduleNextIfReady() {
        lock.lock()
        guard running, !isScheduling else {
            lock.unlock()
            return
        }
        guard queue.nextChunkDuration != nil,
              hasStartedPlayback || queue.queuedDuration >= initialBufferingDuration else {
            lock.unlock()
            return
        }
        isScheduling = true
        let scheduledGeneration = generation
        var chunks = [PCMChunk]()
        while let nextDuration = queue.nextChunkDuration {
            // Always keep one successor ready. The duration bound applies
            // after that minimum continuity window; each accepted chunk is
            // itself bounded by the queue's maximum duration.
            if scheduledChunkCount >= 2,
               scheduledDuration + nextDuration > maxScheduledDuration + 0.000_000_001 {
                break
            }
            guard let next = queue.dequeue() else { break }
            hasStartedPlayback = true
            scheduledChunkCount += 1
            scheduledDuration += nextDuration
            chunks.append(next)
        }
        lock.unlock()

        for chunk in chunks {
            let duration = chunk.playbackDuration
            renderer.schedule(chunk) { [weak self] in
                self?.didFinish(chunkGeneration: scheduledGeneration, duration: duration)
            }
        }

        lock.lock()
        isScheduling = false
        lock.unlock()
        // Pick up output that arrived while this scheduling pass was active.
        if !chunks.isEmpty { scheduleNextIfReady() }
    }

    private func didFinish(chunkGeneration: UInt64, duration: TimeInterval) {
        lock.lock()
        guard running, generation == chunkGeneration else {
            lock.unlock()
            return
        }
        scheduledChunkCount = max(0, scheduledChunkCount - 1)
        scheduledDuration = max(0, scheduledDuration - duration)
        lock.unlock()
        refreshPlaybackRate()
        scheduleNextIfReady()
    }
}

/// Concrete renderer backed by AVAudioEngine + AVAudioPlayerNode.
public final class AVAudioEnginePlaybackRenderer: @unchecked Sendable, PCMPlaybackRenderer {
    public let engine: AVAudioEngine
    public let playerNode: AVAudioPlayerNode
    public let timePitchNode: AVAudioUnitTimePitch
    public let mixerNode: AVAudioMixerNode
    public let format: AVAudioFormat

    private let lock = NSLock()
    private var graphConnected = false

    public init(
        engine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode(),
        timePitchNode: AVAudioUnitTimePitch = AVAudioUnitTimePitch()
    ) {
        self.engine = engine
        self.playerNode = playerNode
        self.timePitchNode = timePitchNode
        self.mixerNode = engine.mainMixerNode
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(JapanesePlaybackFormat.sampleRate),
            channels: AVAudioChannelCount(JapanesePlaybackFormat.channels),
            interleaved: false
        )!
    }

    public func start() throws {
        configureGraphIfNeeded()

        if !engine.isRunning {
            try engine.start()
        }
        playerNode.play()
    }

    func configureGraphIfNeeded() {
        lock.lock()
        if !graphConnected {
            engine.attach(playerNode)
            engine.attach(timePitchNode)
            engine.connect(playerNode, to: timePitchNode, format: format)
            engine.connect(timePitchNode, to: mixerNode, format: format)
            graphConnected = true
        }
        lock.unlock()
    }

    public func stop() {
        playerNode.stop()
        engine.stop()
    }

    public func clearScheduled() {
        playerNode.stop()
        if engine.isRunning { playerNode.play() }
    }

    public func setVolume(_ volume: Float) {
        mixerNode.outputVolume = min(1, max(0, volume))
    }

    public func setPlaybackRate(_ rate: Double) {
        timePitchNode.rate = Float(TranslationTempoController.clampedRenderRate(rate))
    }

    public func schedule(_ chunk: PCMChunk, completion: @escaping @Sendable () -> Void) {
        guard chunk.isJapanesePlaybackFormat, !chunk.samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(chunk.samples.count)
              ), let data = buffer.floatChannelData?[0] else {
            completion()
            return
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        for index in chunk.samples.indices {
            data[index] = Float(chunk.samples[index]) / 32_768
        }
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            completion()
        }
    }
}
