import XCTest
@testable import MimiForMac

final class MetricsTests: XCTestCase {
    func testMetricsExposeCountLevelChecksumWithoutPersistingSamples() {
        let metrics = CaptureMetricsCollector()
        metrics.ingest(AudioSampleBuffer(sampleRate: 48_000, channels: 2, samples: [0.5, -0.5, 0.25, -0.25]))
        let snapshot = metrics.snapshot()

        XCTAssertEqual(snapshot.bufferCount, 1)
        XCTAssertEqual(snapshot.sampleCount, 4)
        XCTAssertEqual(snapshot.sampleRate, 48_000)
        XCTAssertEqual(snapshot.channelCount, 2)
        XCTAssertGreaterThan(snapshot.rmsLevel, 0)
        XCTAssertNotEqual(snapshot.checksum, 0)
        XCTAssertFalse(metrics.hasRawAudioStorage)
    }
}
