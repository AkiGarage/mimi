import Foundation

/// A clock whose value only moves forward while the process is running.
///
/// Production code uses `DispatchTime.uptimeNanoseconds`; tests can provide a
/// small deterministic clock without sleeping or depending on wall time.
public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
}

public struct SystemMonotonicClock: MonotonicClock, Sendable {
    public init() {}

    public func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

public struct ClosureMonotonicClock: MonotonicClock, @unchecked Sendable {
    private let body: @Sendable () -> TimeInterval

    public init(_ body: @escaping @Sendable () -> TimeInterval) {
        self.body = body
    }

    public func now() -> TimeInterval { body() }
}

/// Per-session forgotten-session protection.
///
/// `start()` starts a fresh session. Time is added only between
/// `beginAudioSending()` and `endAudioSending()`, so time spent paused,
/// connecting, or idle does not consume the safety window.
public final class AutoStopTimer: @unchecked Sendable {
    public static let defaultLimitMinutes = 30
    public static let minimumLimitMinutes = 1
    public static let maximumLimitMinutes = 120

    private let lock = NSLock()
    private let clock: any MonotonicClock
    private var started = false
    private var sending = false
    private var elapsed: TimeInterval = 0
    private var sendingStartedAt: TimeInterval?
    private var configuredLimitMinutes: Int

    public init(limitMinutes: Int = AutoStopTimer.defaultLimitMinutes, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.configuredLimitMinutes = Self.clampMinutes(limitMinutes)
        self.clock = clock
    }

    public convenience init(minutes: Int, clock: any MonotonicClock = SystemMonotonicClock()) {
        self.init(limitMinutes: minutes, clock: clock)
    }

    public convenience init(limitMinutes: Int = AutoStopTimer.defaultLimitMinutes, clock: @escaping @Sendable () -> TimeInterval) {
        self.init(limitMinutes: limitMinutes, clock: ClosureMonotonicClock(clock))
    }

    public static func clampMinutes(_ value: Int) -> Int {
        min(max(value, minimumLimitMinutes), maximumLimitMinutes)
    }

    public var limitMinutes: Int {
        lock.lock(); defer { lock.unlock() }
        return configuredLimitMinutes
    }

    public var limitSeconds: TimeInterval {
        TimeInterval(limitMinutes * 60)
    }

    /// Changing the setting affects the current session but does not reset it.
    /// Values outside the supported UI range are clamped to the nearest bound.
    public func setLimitMinutes(_ value: Int) {
        lock.lock(); configuredLimitMinutes = Self.clampMinutes(value); lock.unlock()
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        started = true
        sending = false
        elapsed = 0
        sendingStartedAt = nil
        lock.unlock()
        return true
    }

    /// Continues the same logical listening session after a capture target
    /// handoff. Unlike `start()`, previously consumed audio time is preserved.
    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        syncElapsedLocked(at: clock.now())
        started = true
        sending = false
        sendingStartedAt = nil
        let allowed = elapsed < limitSecondsLocked
        lock.unlock()
        return allowed
    }

    /// Stops the current session. Calling this repeatedly is safe.
    public func stop() {
        lock.lock()
        syncElapsedLocked(at: clock.now())
        started = false
        sending = false
        sendingStartedAt = nil
        lock.unlock()
    }

    @discardableResult
    public func beginAudioSending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return false }
        syncElapsedLocked(at: clock.now())
        guard elapsed < limitSecondsLocked else { return false }
        if !sending {
            sending = true
            sendingStartedAt = clock.now()
        }
        return true
    }

    public func endAudioSending() {
        lock.lock()
        syncElapsedLocked(at: clock.now())
        sending = false
        sendingStartedAt = nil
        lock.unlock()
    }

    // Explicit aliases make the audio-boundary seam read naturally at call sites.
    @discardableResult public func audioSendingStarted() -> Bool { beginAudioSending() }
    public func audioSendingStopped() { endAudioSending() }

    /// Records a known amount of audio-send time (for chunked pipelines).
    /// The value is ignored unless a session is currently sending audio.
    @discardableResult
    public func recordAudioSending(seconds: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard started, sending, seconds.isFinite, seconds > 0 else { return 0 }
        syncElapsedLocked(at: clock.now())
        let accepted = min(seconds, max(0, limitSecondsLocked - elapsed))
        elapsed += accepted
        return accepted
    }

    public var activeAudioSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        syncElapsedLocked(at: clock.now())
        return elapsed
    }

    public var remainingAudioSeconds: TimeInterval {
        max(0, limitSeconds - activeAudioSeconds)
    }

    public var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        guard started else { return false }
        syncElapsedLocked(at: clock.now())
        return elapsed >= limitSecondsLocked
    }

    public var isStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    public var isAudioSending: Bool {
        lock.lock(); defer { lock.unlock() }
        return sending
    }

    private func syncElapsedLocked(at now: TimeInterval) {
        guard sending, let start = sendingStartedAt else { return }
        let delta = now - start
        if delta.isFinite, delta > 0 {
            elapsed = min(limitSecondsLocked, elapsed + delta)
        }
        sendingStartedAt = now
    }

    private var limitSecondsLocked: TimeInterval {
        TimeInterval(configuredLimitMinutes * 60)
    }
}
