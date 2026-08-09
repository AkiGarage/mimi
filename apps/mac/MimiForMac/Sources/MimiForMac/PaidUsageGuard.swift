import Foundation

public protocol WallClock: Sendable {
    func now() -> Date
}

public struct SystemWallClock: WallClock, Sendable {
    public init() {}

    public func now() -> Date { Date() }
}

public struct ClosureWallClock: WallClock, @unchecked Sendable {
    private let body: @Sendable () -> Date

    public init(_ body: @escaping @Sendable () -> Date) {
        self.body = body
    }

    public func now() -> Date { body() }
}

/// The user-selected billing path. The API key is deliberately absent: key
/// contents must never be inspected to infer whether this protection applies.
public enum PaidUsageMode: String, Codable, Sendable {
    case free
    case paidProtected
}

public struct PaidUsageState: Codable, Equatable, Sendable {
    public var monthIdentifier: String
    public var usedAudioSeconds: TimeInterval
    public var lastWallClock: Date?

    public init(monthIdentifier: String, usedAudioSeconds: TimeInterval, lastWallClock: Date? = nil) {
        self.monthIdentifier = monthIdentifier
        self.usedAudioSeconds = max(0, usedAudioSeconds.isFinite ? usedAudioSeconds : 0)
        self.lastWallClock = lastWallClock
    }
}

public protocol PaidUsageStore: Sendable {
    func load() throws -> PaidUsageState?
    func save(_ state: PaidUsageState) throws
}

/// A lock-protected store useful for tests and for embedding the guard in a
/// host that already owns its persistence lifecycle.
public final class InMemoryPaidUsageStore: PaidUsageStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PaidUsageState?

    public init(state: PaidUsageState? = nil) { self.state = state }

    public func load() throws -> PaidUsageState? {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func save(_ state: PaidUsageState) throws {
        lock.lock(); self.state = state; lock.unlock()
    }
}

/// Atomic JSON persistence under Application Support.
///
/// The default path is `Application Support/MimiForMac/paid-usage.json`.
/// Tests and callers that need an isolated location can pass an explicit URL.
public struct ApplicationSupportPaidUsageStore: PaidUsageStore, Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = base
                .appendingPathComponent("MimiForMac", isDirectory: true)
                .appendingPathComponent("paid-usage.json")
        }
    }

    public func load() throws -> PaidUsageState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(PaidUsageState.self, from: data)
    }

    public func save(_ state: PaidUsageState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        // Foundation's atomic option writes a sibling temporary file and
        // replaces the destination, so a crash cannot leave a partial JSON.
        try data.write(to: fileURL, options: [.atomic])
    }
}

public typealias ApplicationSupportUsageStore = ApplicationSupportPaidUsageStore

/// Monthly local safety protection for explicitly enabled paid-key mode.
/// Free mode keeps no Mimi-side monthly allowance and never stops for usage.
public final class PaidUsageGuard: @unchecked Sendable {
    public static let defaultLimitMinutes = 30
    public static let minimumLimitMinutes = 1

    private let lock = NSLock()
    private let store: any PaidUsageStore
    private let monotonicClock: any MonotonicClock
    private let wallClock: any WallClock
    private let protectionEnabled: Bool
    private var configuredLimitMinutes: Int
    private var state: PaidUsageState
    private var started = false
    private var sending = false
    private var sendingStartedAt: TimeInterval?
    private var _lastPersistenceError: String?

    public var lastPersistenceError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastPersistenceError
    }

    public init(
        mode: PaidUsageMode = .free,
        limitMinutes: Int = PaidUsageGuard.defaultLimitMinutes,
        store: any PaidUsageStore = ApplicationSupportPaidUsageStore(),
        monotonicClock: any MonotonicClock = SystemMonotonicClock(),
        wallClock: any WallClock = SystemWallClock()
    ) {
        self.protectionEnabled = mode == .paidProtected
        self.configuredLimitMinutes = max(Self.minimumLimitMinutes, limitMinutes)
        self.store = store
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        let now = wallClock.now()
        let currentMonth = Self.monthIdentifier(for: now)
        let loadedState = try? store.load()
        if let loaded = loadedState {
            if loaded.monthIdentifier >= currentMonth {
                self.state = loaded
            } else {
                self.state = PaidUsageState(monthIdentifier: currentMonth, usedAudioSeconds: 0, lastWallClock: now)
                try? store.save(self.state)
            }
        } else {
            self.state = PaidUsageState(monthIdentifier: currentMonth, usedAudioSeconds: 0, lastWallClock: now)
        }
    }

    public convenience init(
        protectionEnabled: Bool,
        limitMinutes: Int = PaidUsageGuard.defaultLimitMinutes,
        store: any PaidUsageStore = ApplicationSupportPaidUsageStore(),
        monotonicClock: any MonotonicClock = SystemMonotonicClock(),
        wallClock: any WallClock = SystemWallClock()
    ) {
        self.init(
            mode: protectionEnabled ? .paidProtected : .free,
            limitMinutes: limitMinutes,
            store: store,
            monotonicClock: monotonicClock,
            wallClock: wallClock
        )
    }

    public convenience init(
        mode: PaidUsageMode = .free,
        limitMinutes: Int = PaidUsageGuard.defaultLimitMinutes,
        store: any PaidUsageStore = ApplicationSupportPaidUsageStore(),
        monotonicClock: @escaping @Sendable () -> TimeInterval,
        wallClock: @escaping @Sendable () -> Date
    ) {
        self.init(
            mode: mode,
            limitMinutes: limitMinutes,
            store: store,
            monotonicClock: ClosureMonotonicClock(monotonicClock),
            wallClock: ClosureWallClock(wallClock)
        )
    }

    public var isProtectionEnabled: Bool { protectionEnabled }

    public var limitMinutes: Int {
        lock.lock(); defer { lock.unlock() }
        return configuredLimitMinutes
    }

    public func setLimitMinutes(_ value: Int) {
        lock.lock(); configuredLimitMinutes = max(Self.minimumLimitMinutes, value); lock.unlock()
    }

    public var limitSeconds: TimeInterval { TimeInterval(limitMinutes * 60) }

    public var monthIdentifier: String {
        lock.lock(); defer { lock.unlock() }
        refreshMonthLocked()
        return state.monthIdentifier
    }

    /// Free mode intentionally returns zero rather than a fake monthly count.
    public var usedAudioSeconds: TimeInterval {
        guard protectionEnabled else { return 0 }
        lock.lock(); defer { lock.unlock() }
        syncSendingLocked()
        return state.usedAudioSeconds
    }

    public var remainingAudioSeconds: TimeInterval? {
        guard protectionEnabled else { return nil }
        lock.lock(); defer { lock.unlock() }
        syncSendingLocked()
        return max(0, limitSecondsLocked - state.usedAudioSeconds)
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        refreshMonthLocked()
        syncSendingLocked()
        started = true
        sending = false
        sendingStartedAt = nil
        let allowed = !protectionEnabled || state.usedAudioSeconds < limitSecondsLocked
        lock.unlock()
        return allowed
    }

    public func stop() {
        lock.lock()
        syncSendingLocked()
        started = false
        sending = false
        sendingStartedAt = nil
        lock.unlock()
    }

    @discardableResult
    public func beginAudioSending() -> Bool {
        lock.lock()
        refreshMonthLocked()
        syncSendingLocked()
        guard started, !shouldStopLocked() else {
            lock.unlock()
            return false
        }
        if !sending {
            sending = true
            sendingStartedAt = monotonicClock.now()
        }
        lock.unlock()
        return true
    }

    public func endAudioSending() {
        lock.lock()
        syncSendingLocked()
        sending = false
        sendingStartedAt = nil
        persistLocked()
        lock.unlock()
    }

    @discardableResult public func audioSendingStarted() -> Bool { beginAudioSending() }
    public func audioSendingStopped() { endAudioSending() }

    /// Adds a measured audio-send duration and immediately checkpoints it.
    @discardableResult
    public func recordAudioSending(seconds: TimeInterval) -> TimeInterval {
        guard protectionEnabled else { return 0 }
        lock.lock()
        refreshMonthLocked()
        syncSendingLocked()
        guard started, sending, seconds.isFinite, seconds > 0 else {
            lock.unlock()
            return 0
        }
        let accepted = min(seconds, max(0, limitSecondsLocked - state.usedAudioSeconds))
        state.usedAudioSeconds += accepted
        persistLocked()
        lock.unlock()
        return accepted
    }

    @discardableResult public func consumeAudio(seconds: TimeInterval) -> TimeInterval { recordAudioSending(seconds: seconds) }

    /// Persists the elapsed sending interval, useful immediately before a
    /// host is terminated or when the process receives a background/crash hint.
    @discardableResult
    public func checkpoint() -> TimeInterval {
        guard protectionEnabled else { return 0 }
        lock.lock()
        refreshMonthLocked()
        syncSendingLocked()
        persistLocked()
        let used = state.usedAudioSeconds
        lock.unlock()
        return used
    }

    public var shouldStop: Bool {
        guard protectionEnabled else { return false }
        lock.lock(); defer { lock.unlock() }
        refreshMonthLocked()
        syncSendingLocked()
        return shouldStopLocked()
    }

    private func shouldStopLocked() -> Bool {
        protectionEnabled && state.usedAudioSeconds >= limitSecondsLocked
    }

    private func syncSendingLocked() {
        guard protectionEnabled, sending, let startedAt = sendingStartedAt else { return }
        let now = monotonicClock.now()
        let delta = now - startedAt
        if delta.isFinite, delta > 0 {
            state.usedAudioSeconds = min(limitSecondsLocked, state.usedAudioSeconds + delta)
            persistLocked()
        }
        sendingStartedAt = now
    }

    private var limitSecondsLocked: TimeInterval {
        TimeInterval(configuredLimitMinutes * 60)
    }

    private func refreshMonthLocked() {
        let now = wallClock.now()
        let current = Self.monthIdentifier(for: now)
        // Lexical YYYY-MM ordering makes rollback safe: an older wall-clock
        // month can never reset usage from the most recently observed month.
        if current > state.monthIdentifier {
            state = PaidUsageState(monthIdentifier: current, usedAudioSeconds: 0, lastWallClock: now)
            persistLocked()
        } else if current == state.monthIdentifier {
            state.lastWallClock = now
        }
    }

    private func persistLocked() {
        do {
            try store.save(state)
            _lastPersistenceError = nil
        } catch {
            // Safety remains fail-closed in memory; callers can expose this
            // category through SafeDiagnostics without retaining the error text.
            _lastPersistenceError = String(describing: type(of: error))
        }
    }

    public static func monthIdentifier(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 1970, components.month ?? 1)
    }
}
