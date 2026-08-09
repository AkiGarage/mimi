import XCTest
@testable import MimiForMac

final class PlaybackPlayerTests: XCTestCase {
    func testSourceAudioVolumeClampsToAudibleRange() {
        let player = SourceAudioPlayer()

        player.volume = 1.5
        XCTAssertEqual(player.volume, 1, accuracy: 0.000_001)
        player.volume = -0.5
        XCTAssertEqual(player.volume, 0, accuracy: 0.000_001)
    }

    func testPlayerBuffersInitialAudioThenSchedulesChunksInArrivalOrder() throws {
        let renderer = FakePlaybackRenderer()
        let player = TranslatedAudioPlayer(renderer: renderer, initialBufferingDuration: 0.02)
        let first = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 1, count: 240))
        let second = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 2, count: 240))

        try player.start()
        XCTAssertTrue(player.enqueue(first))
        XCTAssertEqual(renderer.scheduledChunks, [])
        XCTAssertTrue(player.enqueue(second))
        XCTAssertEqual(renderer.scheduledChunks, [first, second])

        renderer.completeNext()
        XCTAssertEqual(renderer.scheduledChunks, [first, second])
    }

    func testUnderflowDoesNotReplayOrDuplicate() throws {
        let renderer = FakePlaybackRenderer()
        let player = TranslatedAudioPlayer(renderer: renderer, initialBufferingDuration: 0)
        let chunk = PCMChunk(sampleRate: 24_000, channels: 1, samples: [9, 8, 7])

        try player.start()
        XCTAssertTrue(player.enqueue(chunk))
        XCTAssertEqual(renderer.scheduledChunks, [chunk])
        renderer.completeNext()
        XCTAssertEqual(renderer.scheduledChunks, [chunk])
        XCTAssertFalse(player.enqueue(PCMChunk(sampleRate: 24_000, channels: 1, samples: [])))
        XCTAssertEqual(renderer.scheduledChunks, [chunk])
    }

    func testSchedulesNextChunkBeforeCurrentPlaybackCompletesToAvoidAudibleGaps() throws {
        let renderer = FakePlaybackRenderer()
        let player = TranslatedAudioPlayer(renderer: renderer, initialBufferingDuration: 0)
        let first = PCMChunk(
            sampleRate: 24_000,
            channels: 1,
            samples: Array(repeating: 1, count: 7_200)
        )
        let second = PCMChunk(
            sampleRate: 24_000,
            channels: 1,
            samples: Array(repeating: 2, count: 7_200)
        )

        try player.start()
        XCTAssertTrue(player.enqueue(first))
        XCTAssertTrue(player.enqueue(second))

        XCTAssertEqual(
            renderer.scheduledChunks,
            [first, second],
            "The next PCM buffer must already be scheduled before the current buffer finishes."
        )
    }

    func testScheduledLookAheadRemainsBounded() throws {
        let renderer = FakePlaybackRenderer()
        let player = TranslatedAudioPlayer(
            renderer: renderer,
            maxQueueDuration: 0.2,
            initialBufferingDuration: 0
        )
        let chunks = (1...3).map { value in
            PCMChunk(
                sampleRate: 24_000,
                channels: 1,
                samples: Array(repeating: Int16(value), count: 2_400)
            )
        }

        try player.start()
        for chunk in chunks { XCTAssertTrue(player.enqueue(chunk)) }

        XCTAssertEqual(renderer.scheduledChunks, Array(chunks.prefix(2)))
        XCTAssertEqual(player.queuedDuration, 0.1, accuracy: 0.000_001)

        renderer.completeNext()
        XCTAssertEqual(renderer.scheduledChunks, chunks)
    }

    func testVolumeIsClampedAndStopFlushAreIdempotent() throws {
        let renderer = FakePlaybackRenderer()
        let player = TranslatedAudioPlayer(renderer: renderer)

        player.volume = 1.5
        XCTAssertEqual(renderer.volume, 1, accuracy: 0.000_001)
        player.volume = -0.5
        XCTAssertEqual(renderer.volume, 0, accuracy: 0.000_001)
        try player.start()
        player.flush()
        player.flush()
        player.stop()
        player.stop()

        XCTAssertEqual(renderer.startCount, 1)
        XCTAssertEqual(renderer.stopCount, 1)
        XCTAssertEqual(renderer.clearScheduledCount, 2)
    }

    func testStaleCompletionAfterStopAndRestartCannotScheduleOldAudio() throws {
        let renderer = FakePlaybackRenderer()
        let player = TranslatedAudioPlayer(renderer: renderer, initialBufferingDuration: 0)
        let first = PCMChunk(sampleRate: 24_000, channels: 1, samples: [1])
        let second = PCMChunk(sampleRate: 24_000, channels: 1, samples: [2])

        try player.start()
        XCTAssertTrue(player.enqueue(first))
        player.stop()
        try player.start()
        XCTAssertTrue(player.enqueue(second))
        renderer.complete(at: 0)

        XCTAssertEqual(renderer.scheduledChunks, [first, second])
        XCTAssertEqual(renderer.pendingCompletionCount, 1)
    }
}

private final class FakePlaybackRenderer: PCMPlaybackRenderer, @unchecked Sendable {
    private(set) var scheduledChunks = [PCMChunk]()
    private(set) var completions = [@Sendable () -> Void]()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var clearScheduledCount = 0
    private(set) var volume: Float = 1

    var pendingCompletionCount: Int { completions.count }

    func start() throws { startCount += 1 }

    func stop() { stopCount += 1 }

    func clearScheduled() { clearScheduledCount += 1 }

    func setVolume(_ volume: Float) { self.volume = volume }

    func setPlaybackRate(_ rate: Double) {}

    func schedule(_ chunk: PCMChunk, completion: @escaping @Sendable () -> Void) {
        scheduledChunks.append(chunk)
        completions.append(completion)
    }

    func completeNext() {
        guard !completions.isEmpty else { return }
        let completion = completions.removeFirst()
        completion()
    }

    func complete(at index: Int) {
        guard completions.indices.contains(index) else { return }
        let completion = completions.remove(at: index)
        completion()
    }
}
