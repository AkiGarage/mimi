import XCTest
@testable import MimiForMac

final class AudioConverterTests: XCTestCase {
    func testResamplerPreservesFractionalPhaseAcrossInputBoundaries() throws {
        let full = (0..<5_000).map { Float($0 % 97) / 96 }
        let oneShot = try StreamingPCMConverter(inputSampleRate: 44_100, inputChannels: 1)
        let split = try StreamingPCMConverter(inputSampleRate: 44_100, inputChannels: 1)

        let expected = oneShot.append(full).flatMap(\.samples)
        var actual = split.append(Array(full.prefix(17))).flatMap(\.samples)
        actual += split.append(Array(full.dropFirst(17).prefix(23))).flatMap(\.samples)
        actual += split.append(Array(full.dropFirst(40))).flatMap(\.samples)

        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.isEmpty)
    }

    func testConverterEmitsMonoInt16ChunksOfAbout100Milliseconds() throws {
        let converter = try StreamingPCMConverter(inputSampleRate: 48_000, inputChannels: 2)
        let frames = 4_800
        var stereo = [Float]()
        stereo.reserveCapacity(frames * 2)
        for index in 0..<frames {
            let value = Float(index % 2 == 0 ? 0.25 : -0.25)
            stereo.append(value)
            stereo.append(value)
        }

        let chunks = converter.append(stereo)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].sampleRate, 16_000)
        XCTAssertEqual(chunks[0].channels, 1)
        XCTAssertEqual(chunks[0].samples.count, 1_600)
        XCTAssertEqual(chunks[0].samples.first, 8_192)
        XCTAssertEqual(chunks[0].samples.last, -8_192)
    }

    func testConverterClampsFloatToSignedInt16() throws {
        let converter = try StreamingPCMConverter(inputSampleRate: 16_000, inputChannels: 1)
        let chunks = converter.append([2, -2] + Array(repeating: Float.zero, count: 1_600))
        XCTAssertEqual(Array(chunks[0].samples.prefix(2)), [32_767, -32_768])
    }
}
