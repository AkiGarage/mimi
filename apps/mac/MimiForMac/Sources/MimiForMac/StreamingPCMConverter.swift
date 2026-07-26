import Foundation

public enum AudioConverterError: Error, Sendable, Equatable {
    case invalidSampleRate
    case invalidChannelCount
    case malformedInterleavedSamples(expectedMultipleOf: Int, actualCount: Int)
}

/// Streaming linear resampler with persistent fractional phase and 100 ms packetization.
/// It intentionally retains only a small in-memory interpolation window.
public final class StreamingPCMConverter: @unchecked Sendable {
    public let inputSampleRate: Double
    public let inputChannels: Int
    public let outputSampleRate: Int
    public let chunkFrameCount: Int

    private let ratio: Double
    private var monoSamples: [Float] = []
    private var phase: Double = 0
    private var pendingPCM: [Int16] = []
    private let lock = NSLock()

    public init(
        inputSampleRate: Double,
        inputChannels: Int,
        outputSampleRate: Int = 16_000,
        chunkDuration: TimeInterval = 0.1
    ) throws {
        guard inputSampleRate.isFinite, inputSampleRate > 0 else { throw AudioConverterError.invalidSampleRate }
        guard inputChannels > 0 else { throw AudioConverterError.invalidChannelCount }
        guard outputSampleRate > 0, chunkDuration > 0 else { throw AudioConverterError.invalidSampleRate }
        self.inputSampleRate = inputSampleRate
        self.inputChannels = inputChannels
        self.outputSampleRate = outputSampleRate
        self.chunkFrameCount = max(1, Int((Double(outputSampleRate) * chunkDuration).rounded()))
        self.ratio = inputSampleRate / Double(outputSampleRate)
    }

    /// Appends interleaved Float32 frames and emits only complete ~100 ms chunks.
    public func append(_ interleavedSamples: [Float]) -> [PCMChunk] {
        lock.lock()
        defer { lock.unlock() }
        guard !interleavedSamples.isEmpty else { return [] }
        guard interleavedSamples.count.isMultiple(of: inputChannels) else { return [] }

        monoSamples.reserveCapacity(monoSamples.count + interleavedSamples.count / inputChannels)
        if inputChannels == 1 {
            monoSamples.append(contentsOf: interleavedSamples)
        } else {
            for frameStart in stride(from: 0, to: interleavedSamples.count, by: inputChannels) {
                var sum: Float = 0
                for channel in 0..<inputChannels { sum += interleavedSamples[frameStart + channel] }
                monoSamples.append(sum / Float(inputChannels))
            }
        }

        var produced = [PCMChunk]()
        while true {
            let index = Int(floor(phase))
            guard index + 1 < monoSamples.count else { break }
            let fraction = Float(phase - Double(index))
            let value = monoSamples[index] + (monoSamples[index + 1] - monoSamples[index]) * fraction
            pendingPCM.append(Self.toInt16(value))
            phase += ratio
        }

        let consumed = min(Int(floor(phase)), monoSamples.count - 1)
        if consumed > 0 {
            monoSamples.removeFirst(consumed)
            phase -= Double(consumed)
        }

        while pendingPCM.count >= chunkFrameCount {
            produced.append(PCMChunk(samples: Array(pendingPCM.prefix(chunkFrameCount))))
            pendingPCM.removeFirst(chunkFrameCount)
        }
        return produced
    }

    /// Emits any complete final chunk while deliberately dropping an incomplete tail.
    /// A future transport may choose a padding policy; V1 never invents audio samples.
    public func finish() -> [PCMChunk] {
        lock.lock()
        defer { lock.unlock() }
        guard pendingPCM.count >= chunkFrameCount else { return [] }
        var chunks = [PCMChunk]()
        while pendingPCM.count >= chunkFrameCount {
            chunks.append(PCMChunk(samples: Array(pendingPCM.prefix(chunkFrameCount))))
            pendingPCM.removeFirst(chunkFrameCount)
        }
        return chunks
    }

    public var pendingSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingPCM.count
    }

    private static func toInt16(_ value: Float) -> Int16 {
        let clamped = min(1, max(-1, value))
        if clamped >= 1 { return Int16.max }
        if clamped <= -1 { return Int16.min }
        return Int16((clamped * 32_768).rounded(.toNearestOrAwayFromZero))
    }
}
