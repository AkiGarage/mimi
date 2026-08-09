import Foundation

public enum SafeDiagnosticState: String, Codable, CaseIterable, Sendable {
    case idle
    case selectingSource = "selecting_source"
    case ready
    case connecting
    case listening
    case reconnecting
    case stopping
    case stopped
    case error
    case autoStopReached = "auto_stop_reached"
    case paidLimitReached = "paid_limit_reached"
    case sourceEnded = "source_ended"
    case unknown
}

public enum SafeDiagnosticErrorCategory: String, Codable, CaseIterable, Sendable {
    case network
    case authentication
    case quota
    case billing
    case permission
    case sourceEnded = "source_ended"
    case timeout
    case unknown
}

public struct SafeAudioFormat: Codable, Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let sampleFormat: String

    public init(sampleRate: Int, channels: Int, sampleFormat: String) {
        self.sampleRate = min(max(sampleRate, 0), 384_000)
        self.channels = min(max(channels, 0), 32)
        // Keep a format label, never a payload. Unknown labels are represented
        // generically so callers cannot smuggle content through this field.
        let normalized = sampleFormat.lowercased()
        self.sampleFormat = ["pcm_s16le", "pcm_s24le", "pcm_f32le", "unknown"].contains(normalized)
            ? normalized
            : "unknown"
    }
}

public struct SafeDiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let state: SafeDiagnosticState?
    public let durationSeconds: TimeInterval?
    public let audioFormat: SafeAudioFormat?
    public let bufferCount: Int?
    public let queueDepth: Int?
    public let errorCategory: SafeDiagnosticErrorCategory?

    public init(
        timestamp: Date = Date(),
        state: SafeDiagnosticState? = nil,
        durationSeconds: TimeInterval? = nil,
        audioFormat: SafeAudioFormat? = nil,
        bufferCount: Int? = nil,
        queueDepth: Int? = nil,
        errorCategory: SafeDiagnosticErrorCategory? = nil
    ) {
        self.timestamp = timestamp
        self.state = state
        self.durationSeconds = Self.boundDuration(durationSeconds)
        self.audioFormat = audioFormat
        self.bufferCount = Self.boundCount(bufferCount)
        self.queueDepth = Self.boundCount(queueDepth)
        self.errorCategory = errorCategory
    }

    private static func boundDuration(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 86_400)
    }

    private static func boundCount(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return min(max(value, 0), 1_000_000_000)
    }
}

/// In-memory, bounded diagnostics that expose state metadata only.
///
/// The API deliberately accepts only counters, formats, state enums, and an
/// error *category*. A raw error string may be supplied through `errorCode` for
/// convenience, but it is immediately mapped to a fixed category and never
/// retained or emitted.
public final class SafeDiagnostics: @unchecked Sendable {
    public static let defaultMaxEvents = 100
    public static let defaultMaxBytes = 64 * 1024

    private let lock = NSLock()
    private let maxEvents: Int
    private let maxBytes: Int
    private var events: [SafeDiagnosticEvent] = []

    public init(maxEvents: Int = SafeDiagnostics.defaultMaxEvents, maxBytes: Int = SafeDiagnostics.defaultMaxBytes) {
        self.maxEvents = max(1, maxEvents)
        self.maxBytes = max(1, maxBytes)
    }

    public func record(
        timestamp: Date = Date(),
        state: SafeDiagnosticState? = nil,
        durationSeconds: TimeInterval? = nil,
        audioFormat: SafeAudioFormat? = nil,
        bufferCount: Int? = nil,
        queueDepth: Int? = nil,
        errorCategory: SafeDiagnosticErrorCategory? = nil
    ) {
        append(SafeDiagnosticEvent(
            timestamp: timestamp,
            state: state,
            durationSeconds: durationSeconds,
            audioFormat: audioFormat,
            bufferCount: bufferCount,
            queueDepth: queueDepth,
            errorCategory: errorCategory
        ))
    }

    /// String-facing convenience that maps labels to allow-listed values.
    /// Neither `state` nor `errorCode` is retained verbatim.
    public func record(
        timestamp: Date = Date(),
        state: String? = nil,
        durationSeconds: TimeInterval? = nil,
        audioFormat: SafeAudioFormat? = nil,
        bufferCount: Int? = nil,
        queueDepth: Int? = nil,
        errorCode: String? = nil
    ) {
        let safeState = state.flatMap(Self.state(from:))
        let safeCategory = errorCode.flatMap(Self.errorCategory(from:))
        record(
            timestamp: timestamp,
            state: safeState,
            durationSeconds: durationSeconds,
            audioFormat: audioFormat,
            bufferCount: bufferCount,
            queueDepth: queueDepth,
            errorCategory: safeCategory
        )
    }

    public func snapshot() -> [SafeDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// Encodes the current bounded snapshot. It can be written to a local log
    /// without including audio, transcript, URL, key, title, or identifier data.
    public func encodedData() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !events.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var candidate = events
        while !candidate.isEmpty {
            let data = try encoder.encode(candidate)
            if data.count <= maxBytes { return data }
            candidate.removeFirst()
        }
        return nil
    }

    public func redactedJSON() throws -> String? {
        guard let data = try encodedData() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func state(from raw: String) -> SafeDiagnosticState? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SafeDiagnosticState(rawValue: normalized)
    }

    public static func errorCategory(from raw: String) -> SafeDiagnosticErrorCategory {
        let value = raw.lowercased()
        if value.contains("auth") || value.contains("credential") || value.contains("api key") || value.contains("apikey") {
            return .authentication
        }
        if value.contains("quota") || value.contains("free tier") || value.contains("rate limit") {
            return .quota
        }
        if value.contains("billing") || value.contains("paid") || value.contains("payment") {
            return .billing
        }
        if value.contains("permission") || value.contains("access denied") {
            return .permission
        }
        if value.contains("timeout") {
            return .timeout
        }
        if value.contains("network") || value.contains("socket") || value.contains("connect") || value.contains("http") || value.contains("url") {
            return .network
        }
        if value.contains("source") || value.contains("process ended") {
            return .sourceEnded
        }
        return .unknown
    }

    private func append(_ event: SafeDiagnosticEvent) {
        lock.lock()
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
        lock.unlock()
    }
}
