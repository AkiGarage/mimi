import Foundation
import XCTest
@testable import MimiForMac

final class PlaybackQueueTests: XCTestCase {
    func testQueuePreservesFIFOOrderAndTracksAudioDuration() throws {
        var queue = PCMPlaybackQueue(maxDuration: 0.2)
        let first = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 11, count: 2_400))
        let second = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 22, count: 1_200))

        XCTAssertEqual(queue.enqueue(first), .accepted)
        XCTAssertEqual(queue.enqueue(second), .accepted)
        XCTAssertEqual(queue.queuedDuration, 0.15, accuracy: 0.000_001)
        XCTAssertEqual(queue.dequeue(), first)
        XCTAssertEqual(queue.dequeue(), second)
        XCTAssertNil(queue.dequeue())
        XCTAssertEqual(queue.queuedDuration, 0, accuracy: 0.000_001)
    }

    func testOverflowDropsOldestCompleteChunksDeterministically() throws {
        var queue = PCMPlaybackQueue(maxDuration: 0.2)
        let first = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 1, count: 2_400))
        let second = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 2, count: 2_400))
        let third = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 3, count: 2_400))

        XCTAssertEqual(queue.enqueue(first), .accepted)
        XCTAssertEqual(queue.enqueue(second), .accepted)
        let result = queue.enqueue(third)
        XCTAssertEqual(result, .acceptedAfterDroppingOldest(chunkCount: 1, duration: 0.1))
        XCTAssertEqual(queue.droppedChunkCount, 1)
        XCTAssertEqual(queue.queuedDuration, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(queue.dequeue(), second)
        XCTAssertEqual(queue.dequeue(), third)
    }

    func testOversizedChunkIsRejectedWithoutChangingQueue() {
        var queue = PCMPlaybackQueue(maxDuration: 0.2)
        let oversized = PCMChunk(sampleRate: 24_000, channels: 1, samples: Array(repeating: 7, count: 4_801))

        XCTAssertEqual(queue.enqueue(oversized), .droppedIncoming)
        XCTAssertEqual(queue.queuedChunkCount, 0)
        XCTAssertEqual(queue.droppedChunkCount, 0)
    }

    func testQueueRejectsNonJapanesePlaybackFormat() {
        var queue = PCMPlaybackQueue(maxDuration: 0.2)
        let wrongRate = PCMChunk(sampleRate: 16_000, channels: 1, samples: [1, 2])
        let wrongChannels = PCMChunk(sampleRate: 24_000, channels: 2, samples: [1, 2])

        XCTAssertEqual(queue.enqueue(wrongRate), .rejectedInvalidFormat)
        XCTAssertEqual(queue.enqueue(wrongChannels), .rejectedInvalidFormat)
        XCTAssertEqual(queue.queuedChunkCount, 0)
    }

    func testLittleEndianPCMDecoderUsesByteOrderAndRejectsOddPayload() throws {
        let chunk = try PCMPlaybackDataDecoder.decode(Data([0x01, 0x00, 0xff, 0xff, 0x00, 0x80]))
        XCTAssertEqual(chunk, PCMChunk(sampleRate: 24_000, channels: 1, samples: [1, -1, -32_768]))
        XCTAssertThrowsError(try PCMPlaybackDataDecoder.decode(Data([0x01]))) { error in
            XCTAssertEqual(error as? PlaybackError, .invalidPCMByteCount)
        }
    }
}
