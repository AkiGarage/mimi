import Foundation

/// The only PCM format accepted by the native Japanese playback path.
public enum JapanesePlaybackFormat {
    public static let sampleRate = 24_000
    public static let channels = 1
}

public enum PlaybackError: Error, Sendable, Equatable, LocalizedError {
    case invalidPCMByteCount
    case unsupportedPCMFormat(sampleRate: Int, channels: Int)
    case invalidQueueDuration
    case audioBufferCreationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPCMByteCount:
            return "PCM payload must contain an even number of little-endian bytes."
        case let .unsupportedPCMFormat(sampleRate, channels):
            return "Playback requires " + String(JapanesePlaybackFormat.sampleRate)
                + " Hz mono PCM, received " + String(sampleRate)
                + " Hz / " + String(channels) + " channels."
        case .invalidQueueDuration:
            return "Playback queue duration must be greater than zero."
        case .audioBufferCreationFailed:
            return "AVAudioPCMBuffer could not be created for the playback format."
        }
    }
}

/// Decodes Gemini's signed Int16 little-endian mono PCM without retaining the
/// input `Data` object. The returned samples are held only in memory until
/// they are played or flushed.
public enum PCMPlaybackDataDecoder {
    public static func decode(_ data: Data) throws -> PCMChunk {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw PlaybackError.invalidPCMByteCount
        }
        var samples = [Int16]()
        samples.reserveCapacity(data.count / MemoryLayout<Int16>.size)
        for index in stride(from: 0, to: data.count, by: 2) {
            let low = UInt16(data[index])
            let high = UInt16(data[index + 1]) << 8
            samples.append(Int16(bitPattern: low | high))
        }
        return PCMChunk(
            sampleRate: JapanesePlaybackFormat.sampleRate,
            channels: JapanesePlaybackFormat.channels,
            samples: samples
        )
    }
}

public extension PCMChunk {
    var playbackDuration: TimeInterval {
        guard sampleRate > 0, channels > 0 else { return 0 }
        return Double(samples.count / channels) / Double(sampleRate)
    }

    var isJapanesePlaybackFormat: Bool {
        sampleRate == JapanesePlaybackFormat.sampleRate && channels == JapanesePlaybackFormat.channels
    }

    /// Encodes samples as signed Int16 little-endian PCM for a transport or
    /// an audio fixture. No metadata or persistence is involved.
    func littleEndianData() -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xff))
            data.append(UInt8((bits >> 8) & 0xff))
        }
        return data
    }
}

public struct PCMPlaybackQueueEnqueueOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case accepted
        case acceptedAfterDroppingOldest
        case droppedIncoming
        case rejectedInvalidFormat
    }

    public let kind: Kind
    public let droppedChunkCount: Int
    public let droppedDuration: TimeInterval

    public init(
        kind: Kind,
        droppedChunkCount: Int = 0,
        droppedDuration: TimeInterval = 0
    ) {
        self.kind = kind
        self.droppedChunkCount = droppedChunkCount
        self.droppedDuration = droppedDuration
    }

    public static let accepted = Self(kind: .accepted)
    public static let droppedIncoming = Self(kind: .droppedIncoming)
    public static let rejectedInvalidFormat = Self(kind: .rejectedInvalidFormat)

    public static func acceptedAfterDroppingOldest(
        chunkCount: Int,
        duration: TimeInterval
    ) -> Self {
        Self(
            kind: .acceptedAfterDroppingOldest,
            droppedChunkCount: chunkCount,
            droppedDuration: duration
        )
    }
}

/// A bounded FIFO queue for Japanese output chunks.
///
/// Overflow drops the oldest complete chunks before accepting a new chunk.
/// This keeps the most recent translated audio and, importantly, bounds live
/// latency instead of allowing a producer burst to accumulate indefinitely.
/// Among chunks that remain in the queue, arrival order is always preserved.
public struct PCMPlaybackQueue: Sendable {
    public let maxDuration: TimeInterval
    public let sampleRate: Int
    public let channels: Int

    private var chunks: [PCMChunk] = []
    private var sampleCount = 0
    private(set) public var droppedChunkCount = 0
    private(set) public var droppedDuration: TimeInterval = 0

    public init(
        maxDuration: TimeInterval = 0.5,
        sampleRate: Int = JapanesePlaybackFormat.sampleRate,
        channels: Int = JapanesePlaybackFormat.channels
    ) {
        self.maxDuration = maxDuration
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var queuedChunkCount: Int { chunks.count }

    public var queuedSampleCount: Int { sampleCount }

    public var nextChunkDuration: TimeInterval? { chunks.first?.playbackDuration }

    public var queuedDuration: TimeInterval {
        guard sampleRate > 0, channels > 0 else { return 0 }
        return Double(sampleCount / channels) / Double(sampleRate)
    }

    @discardableResult
    public mutating func enqueue(_ chunk: PCMChunk) -> PCMPlaybackQueueEnqueueOutcome {
        guard chunk.isJapanesePlaybackFormat,
              sampleRate == JapanesePlaybackFormat.sampleRate,
              channels == JapanesePlaybackFormat.channels else {
            return .rejectedInvalidFormat
        }
        guard !chunk.samples.isEmpty else { return .accepted }
        guard maxDuration > 0 else { return .droppedIncoming }

        let chunkDuration = chunk.playbackDuration
        // Chunks are atomic. Reject an individual chunk larger than the bound
        // rather than partially trimming and changing sample continuity.
        guard chunkDuration <= maxDuration else { return .droppedIncoming }

        var droppedCount = 0
        var droppedTime: TimeInterval = 0
        while !chunks.isEmpty, queuedDuration + chunkDuration > maxDuration {
            let dropped = chunks.removeFirst()
            sampleCount -= dropped.samples.count
            droppedCount += 1
            droppedTime += dropped.playbackDuration
            droppedChunkCount += 1
            droppedDuration += dropped.playbackDuration
        }

        // Floating-point rounding should never let a queue exceed the bound.
        // If the queue still cannot fit, reject this chunk atomically.
        guard queuedDuration + chunkDuration <= maxDuration + 0.000_000_001 else {
            return .droppedIncoming
        }

        chunks.append(chunk)
        sampleCount += chunk.samples.count
        if droppedCount > 0 {
            return .acceptedAfterDroppingOldest(chunkCount: droppedCount, duration: droppedTime)
        }
        return .accepted
    }

    public mutating func dequeue() -> PCMChunk? {
        guard !chunks.isEmpty else { return nil }
        let chunk = chunks.removeFirst()
        sampleCount -= chunk.samples.count
        return chunk
    }

    public mutating func flush() {
        chunks.removeAll(keepingCapacity: false)
        sampleCount = 0
    }
}
