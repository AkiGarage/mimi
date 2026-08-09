import Foundation

/// A single in-memory audio buffer delivered by a capture backend.
/// The package never writes this payload to disk.
public struct AudioSampleBuffer: Sendable, Equatable {
    public let sampleRate: Double
    public let channels: Int
    /// Interleaved Float32 samples. The count is `frameCount * channels`.
    public let samples: [Float]

    public init(sampleRate: Double, channels: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }

    public var frameCount: Int { channels > 0 ? samples.count / channels : 0 }
}

/// A normalized chunk ready for a 16 kHz mono PCM transport.
public struct PCMChunk: Sendable, Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let samples: [Int16]

    public init(sampleRate: Int = 16_000, channels: Int = 1, samples: [Int16]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }
}

/// Non-content capture diagnostics. No sample payload is retained.
public struct CaptureMetrics: Sendable, Equatable {
    public let bufferCount: Int
    public let sampleCount: Int
    public let sampleRate: Double?
    public let channelCount: Int?
    public let rmsLevel: Float
    public let checksum: UInt64

    public init(
        bufferCount: Int = 0,
        sampleCount: Int = 0,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        rmsLevel: Float = 0,
        checksum: UInt64 = 0
    ) {
        self.bufferCount = bufferCount
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.rmsLevel = rmsLevel
        self.checksum = checksum
    }
}

/// A lock-based collector keeps only aggregate metrics and a rolling FNV-1a checksum.
public final class CaptureMetricsCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferCount = 0
    private var sampleCount = 0
    private var sampleRate: Double?
    private var channelCount: Int?
    private var sumSquares: Double = 0
    private var checksum: UInt64 = 14_695_981_039_346_656_037

    public init() {}

    public var hasRawAudioStorage: Bool { false }

    public func ingest(_ buffer: AudioSampleBuffer) {
        guard buffer.channels > 0, buffer.sampleRate > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        bufferCount += 1
        sampleCount += buffer.samples.count
        sampleRate = buffer.sampleRate
        channelCount = buffer.channels
        for sample in buffer.samples {
            let value = Double(sample)
            sumSquares += value * value
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes in
                for byte in bytes {
                    checksum ^= UInt64(byte)
                    checksum &*= 1_099_511_628_211
                }
            }
        }
    }

    public func snapshot() -> CaptureMetrics {
        lock.lock()
        defer { lock.unlock() }
        let rms = sampleCount == 0 ? 0 : Float(sqrt(sumSquares / Double(sampleCount)))
        return CaptureMetrics(
            bufferCount: bufferCount,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            channelCount: channelCount,
            rmsLevel: rms,
            checksum: checksum
        )
    }
}
