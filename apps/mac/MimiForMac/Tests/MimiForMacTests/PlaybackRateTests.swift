import AVFoundation
import Foundation
import XCTest
@testable import MimiForMac

final class PlaybackRateTests: XCTestCase {
    func testSupportedRatesAndInvalidValuesNormalizeToOne() {
        XCTAssertEqual(MimiPlaybackRate.supported, [1, 1.25, 1.5, 1.75, 2])
        XCTAssertEqual(MimiPlaybackRate.normalized(1.5), 1.5)
        XCTAssertEqual(MimiPlaybackRate.normalized(1.4), 1)
        XCTAssertEqual(MimiPlaybackRate.normalized(.nan), 1)

        let provider = ManualPlaybackRateProvider(initialRate: 1.25)
        XCTAssertEqual(provider.playbackRate, 1.25)
        provider.update(2)
        XCTAssertEqual(provider.playbackRate, 2)
        provider.update(7)
        XCTAssertEqual(provider.playbackRate, 1)
    }

    func testRuntimeSettingsPersistPlaybackRateAndOldOrInvalidValuesFallback() throws {
        let suiteName = "MimiPlaybackRateSettingsTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = MimiRuntimeSettingsStore(defaults: suite)

        store.save(MimiRuntimeSettings(playbackRate: 1.75))
        XCTAssertEqual(store.load().playbackRate, 1.75)

        suite.set(9.0, forKey: "mimi.runtime-settings.playback-rate")
        XCTAssertEqual(store.load().playbackRate, 1)
        suite.removeObject(forKey: "mimi.runtime-settings.playback-rate")
        XCTAssertEqual(store.load().playbackRate, 1)
    }

    func testTempoControllerUsesSpecifiedBufferThresholdsAndRampLimit() {
        XCTAssertEqual(
            TranslationTempoController.targetRate(baseRate: 1.5, bufferedDuration: 0.20),
            1.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TranslationTempoController.targetRate(baseRate: 1.5, bufferedDuration: 0.35),
            1.625,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TranslationTempoController.targetRate(baseRate: 1.5, bufferedDuration: 0.50),
            1.75,
            accuracy: 0.000_001
        )

        var controller = TranslationTempoController(initialBaseRate: 1)
        XCTAssertEqual(controller.update(baseRate: 2, bufferedDuration: 0.5), 1.1, accuracy: 0.000_001)
        XCTAssertEqual(controller.update(baseRate: 2, bufferedDuration: 0.5), 1.2, accuracy: 0.000_001)
        XCTAssertEqual(controller.update(baseRate: 2, bufferedDuration: 0), 1.3, accuracy: 0.000_001)
    }

    func testTenMinuteVirtualPlaybackDoesNotAccumulateBufferAtSupportedRates() {
        for baseRate in MimiPlaybackRate.supported {
            var controller = TranslationTempoController(initialBaseRate: baseRate)
            var bufferedDuration = 0.5
            let step = 0.1

            for _ in 0..<6_000 {
                let renderRate = controller.update(
                    baseRate: baseRate,
                    bufferedDuration: bufferedDuration
                )
                let next = max(0, bufferedDuration + (baseRate * step) - (renderRate * step))
                XCTAssertLessThanOrEqual(next, bufferedDuration + 0.000_001)
                XCTAssertLessThanOrEqual(next, 0.5 + 0.000_001)
                bufferedDuration = next
            }
        }
    }

    func testManualChangeReachesRunningRendererWithoutRestart() throws {
        let renderer = RateRecordingRenderer()
        let provider = ManualPlaybackRateProvider(initialRate: 1)
        let player = TranslatedAudioPlayer(
            renderer: renderer,
            playbackRateProvider: provider,
            initialBufferingDuration: 0
        )

        try player.start()
        provider.update(2)
        player.refreshPlaybackRate()
        XCTAssertEqual(renderer.startCount, 1)
        XCTAssertEqual(renderer.rates.suffix(2), [1, 1.1])

        let chunk = PCMChunk(
            sampleRate: 24_000,
            channels: 1,
            samples: Array(repeating: 1, count: 2_400)
        )
        XCTAssertTrue(player.enqueue(chunk))
        XCTAssertEqual(try XCTUnwrap(renderer.rates.last), 1.2, accuracy: 0.000_001)

        player.stop()
        try player.start()
        XCTAssertEqual(try XCTUnwrap(renderer.rates.last), 2, accuracy: 0.000_001)
    }

    func testStaleCompletionCannotChangeRateAfterRestart() throws {
        let renderer = RateRecordingRenderer()
        let provider = ManualPlaybackRateProvider(initialRate: 1)
        let player = TranslatedAudioPlayer(
            renderer: renderer,
            playbackRateProvider: provider,
            initialBufferingDuration: 0
        )
        let chunk = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 1, count: 2_400))

        try player.start()
        XCTAssertTrue(player.enqueue(chunk))
        player.stop()
        provider.update(2)
        try player.start()
        let rateCountAfterRestart = renderer.rates.count
        renderer.complete(at: 0)

        XCTAssertEqual(renderer.rates.count, rateCountAfterRestart)
        XCTAssertEqual(try XCTUnwrap(renderer.rates.last), 2, accuracy: 0.000_001)
    }

    func testProductionRendererBuildsTimePitchGraphAndClampsRate() {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        let timePitchNode = AVAudioUnitTimePitch()
        let renderer = AVAudioEnginePlaybackRenderer(
            engine: engine,
            playerNode: playerNode,
            timePitchNode: timePitchNode
        )

        renderer.configureGraphIfNeeded()
        XCTAssertTrue(engine.attachedNodes.contains { $0 === playerNode })
        XCTAssertTrue(engine.attachedNodes.contains { $0 === timePitchNode })
        XCTAssertTrue(
            engine.outputConnectionPoints(for: playerNode, outputBus: 0).contains {
                $0.node === timePitchNode
            }
        )

        renderer.setPlaybackRate(9)
        XCTAssertEqual(timePitchNode.rate, 2.5, accuracy: 0.000_001)
        renderer.setPlaybackRate(.nan)
        XCTAssertEqual(timePitchNode.rate, 1, accuracy: 0.000_001)
    }
}

private final class RateRecordingRenderer: PCMPlaybackRenderer, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var rates = [Double]()
    private var completions = [@Sendable () -> Void]()

    func start() throws { startCount += 1 }
    func stop() {}
    func clearScheduled() { completions.removeAll() }
    func setVolume(_ volume: Float) {}
    func setPlaybackRate(_ rate: Double) { rates.append(rate) }
    func schedule(_ chunk: PCMChunk, completion: @escaping @Sendable () -> Void) {
        completions.append(completion)
    }

    func complete(at index: Int) {
        guard completions.indices.contains(index) else { return }
        completions.remove(at: index)()
    }
}
