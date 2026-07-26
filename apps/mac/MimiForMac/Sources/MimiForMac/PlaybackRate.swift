import Foundation

/// User-selectable speed of the source video or podcast.
///
/// Core Audio only exposes the already-rendered PCM stream, so the standalone
/// app cannot reliably infer a browser player's 1.25x/2x setting. The manual
/// value is therefore the explicit source of truth.
public enum MimiPlaybackRate {
    public static let defaultValue = 1.0
    public static let supported = [1.0, 1.25, 1.5, 1.75, 2.0]

    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return supported.first { abs($0 - value) < 0.000_001 } ?? defaultValue
    }
}

public protocol PlaybackRateProvider: AnyObject, Sendable {
    var playbackRate: Double { get }
}

/// Thread-safe provider shared by the view model and every playback session.
/// Reusing the provider preserves the user's speed across reconnects and
/// source handoffs without coupling the setting to Gemini's transport.
public final class ManualPlaybackRateProvider: @unchecked Sendable, PlaybackRateProvider {
    private let lock = NSLock()
    private var storedRate: Double

    public init(initialRate: Double = MimiPlaybackRate.defaultValue) {
        self.storedRate = MimiPlaybackRate.normalized(initialRate)
    }

    public var playbackRate: Double {
        lock.lock(); defer { lock.unlock() }
        return storedRate
    }

    public func update(_ rate: Double) {
        lock.lock()
        storedRate = MimiPlaybackRate.normalized(rate)
        lock.unlock()
    }
}

/// Converts the selected source speed and current translated-audio backlog
/// into a pitch-preserving render rate. The small catch-up boost keeps live
/// latency bounded while the per-update limit prevents audible speed jumps.
public struct TranslationTempoController: Sendable, Equatable {
    public static let minimumRenderRate = 1.0
    public static let maximumRenderRate = 2.5
    public static let boostStartDuration = 0.20
    public static let maximumBoostDuration = 0.50
    public static let maximumBoost = 0.25
    public static let maximumStep = 0.10

    public private(set) var currentRate: Double

    public init(initialBaseRate: Double = MimiPlaybackRate.defaultValue) {
        self.currentRate = Self.clampedRenderRate(MimiPlaybackRate.normalized(initialBaseRate))
    }

    public static func targetRate(baseRate: Double, bufferedDuration: TimeInterval) -> Double {
        let base = MimiPlaybackRate.normalized(baseRate)
        let buffered = bufferedDuration.isFinite ? max(0, bufferedDuration) : 0
        let boost: Double
        if buffered <= boostStartDuration {
            boost = 0
        } else if buffered >= maximumBoostDuration {
            boost = maximumBoost
        } else {
            let progress = (buffered - boostStartDuration)
                / (maximumBoostDuration - boostStartDuration)
            boost = progress * maximumBoost
        }
        return clampedRenderRate(base + boost)
    }

    @discardableResult
    public mutating func update(baseRate: Double, bufferedDuration: TimeInterval) -> Double {
        let target = Self.targetRate(baseRate: baseRate, bufferedDuration: bufferedDuration)
        let delta = min(Self.maximumStep, max(-Self.maximumStep, target - currentRate))
        currentRate = Self.clampedRenderRate(currentRate + delta)
        return currentRate
    }

    @discardableResult
    public mutating func reset(baseRate: Double) -> Double {
        currentRate = Self.clampedRenderRate(MimiPlaybackRate.normalized(baseRate))
        return currentRate
    }

    public static func clampedRenderRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return MimiPlaybackRate.defaultValue }
        return min(maximumRenderRate, max(minimumRenderRate, rate))
    }
}
