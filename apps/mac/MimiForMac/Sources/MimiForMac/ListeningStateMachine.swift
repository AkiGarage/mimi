import Foundation

public enum ListeningFailure: String, Sendable, Equatable {
    case permission
    case credential
    case network
    case quota
    case billing
    case noAudio
    case unknown
}

public enum ListeningAppState: Sendable, Equatable {
    case needsSetup
    case idle
    case selectingSource
    case ready
    case connecting
    case listening
    case reconnecting
    case stopping
    case autoStopReached
    case paidLimitReached
    case sourceEnded
    case failed(ListeningFailure)

    public var isActive: Bool {
        switch self {
        case .connecting, .listening, .reconnecting, .stopping: true
        default: false
        }
    }
}

/// Serializes UI lifecycle transitions and assigns every session a generation.
/// Callbacks carrying an older generation are ignored.
public actor ListeningStateMachine {
    public private(set) var state: ListeningAppState
    public private(set) var generation: UInt64 = 0
    private var hasSource = false

    public init(isSetupComplete: Bool) {
        state = isSetupComplete ? .idle : .needsSetup
    }

    public func completeSetup() {
        guard state == .needsSetup else { return }
        state = .idle
    }

    public func beginSourceSelection() {
        guard !state.isActive else { return }
        state = .selectingSource
    }

    public func selectSource() {
        guard !state.isActive else { return }
        hasSource = true
        state = .ready
    }

    public func clearSource() {
        guard !state.isActive else { return }
        hasSource = false
        state = .idle
    }

    /// Returns the current generation. Repeated Start while active is coalesced.
    public func start() -> UInt64? {
        if state == .connecting || state == .listening || state == .reconnecting {
            return generation
        }
        guard state == .ready || state == .autoStopReached || state == .sourceEnded,
              hasSource else { return nil }
        generation &+= 1
        state = .connecting
        return generation
    }

    @discardableResult
    public func connected(generation callbackGeneration: UInt64) -> Bool {
        guard accepts(callbackGeneration), state == .connecting || state == .reconnecting else { return false }
        state = .listening
        return true
    }

    @discardableResult
    public func beginReconnect(generation callbackGeneration: UInt64) -> Bool {
        guard accepts(callbackGeneration), state == .listening else { return false }
        state = .reconnecting
        return true
    }

    /// Returns true only for the first Stop request of an active session.
    public func stop() -> Bool {
        guard state == .connecting || state == .listening || state == .reconnecting else { return false }
        state = .stopping
        return true
    }

    public func stopped(generation callbackGeneration: UInt64) {
        guard accepts(callbackGeneration), state == .stopping else { return }
        state = hasSource ? .ready : .idle
    }

    public func terminate(
        generation callbackGeneration: UInt64,
        as terminalState: ListeningAppState
    ) {
        guard accepts(callbackGeneration), terminalState.isAllowedTerminal else { return }
        state = terminalState
    }

    private func accepts(_ callbackGeneration: UInt64) -> Bool {
        callbackGeneration == generation
    }
}

private extension ListeningAppState {
    var isAllowedTerminal: Bool {
        switch self {
        case .autoStopReached, .paidLimitReached, .sourceEnded, .failed: true
        default: false
        }
    }
}
