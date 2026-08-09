import Foundation

/// Selects a new application only after the old target has stopped producing
/// audio and exactly one replacement remains stable for a short interval.
/// This avoids surprising jumps while two apps intentionally play together.
public struct AutomaticAudioTargetHandoffPolicy: Sendable {
    public let stabilityInterval: TimeInterval

    private var pendingTargetID: String?
    private var pendingSince: TimeInterval?

    public init(stabilityInterval: TimeInterval = 1.0) {
        self.stabilityInterval = max(0, stabilityInterval)
    }

    public mutating func nextTarget(
        current: AudioSource,
        activeApplications: [AudioSource],
        now: TimeInterval
    ) -> AudioSource? {
        var applicationsByID = [String: AudioSource]()
        for application in activeApplications { applicationsByID[application.id] = application }
        let unique = applicationsByID.values
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        guard !unique.contains(where: { $0.id == current.id }), unique.count == 1,
              let candidate = unique.first else {
            reset()
            return nil
        }

        guard pendingTargetID == candidate.id, let pendingSince else {
            pendingTargetID = candidate.id
            self.pendingSince = now
            return stabilityInterval == 0 ? candidate : nil
        }
        guard now - pendingSince >= stabilityInterval else { return nil }
        reset()
        return candidate
    }

    public mutating func reset() {
        pendingTargetID = nil
        pendingSince = nil
    }
}

public enum TranslationContextRestartDecision: Equatable, Sendable {
    case none
    case schedule(String)
    case cancelPending
}

/// Keeps target-title observation separate from the async restart task.
/// Once a restart begins, repeated snapshots for the confirmed title must not
/// cancel that task; they are the expected steady-state signal, not a revert.
public struct TranslationContextRestartPolicy: Sendable {
    private var confirmedSignature: String?
    private var pendingSignature: String?
    private var restartingSignature: String?

    public init() {}

    public var isRestartInProgress: Bool { restartingSignature != nil }

    public mutating func observe(
        _ signature: String,
        allowsSessionRestart: Bool = true
    ) -> TranslationContextRestartDecision {
        guard allowsSessionRestart else {
            guard restartingSignature == nil else { return .none }
            let shouldCancelPendingRestart = pendingSignature != nil
            confirmedSignature = signature
            pendingSignature = nil
            return shouldCancelPendingRestart ? .cancelPending : .none
        }
        guard confirmedSignature != nil else {
            confirmedSignature = signature
            return .none
        }
        guard restartingSignature == nil else {
            return .none
        }
        guard signature != confirmedSignature else {
            guard pendingSignature != nil else { return .none }
            pendingSignature = nil
            return .cancelPending
        }
        guard pendingSignature != signature else { return .none }
        pendingSignature = signature
        return .schedule(signature)
    }

    public mutating func beginRestart(for signature: String) -> Bool {
        guard restartingSignature == nil, pendingSignature == signature else { return false }
        confirmedSignature = signature
        pendingSignature = nil
        restartingSignature = signature
        return true
    }

    public mutating func finishRestart(for signature: String) {
        guard restartingSignature == signature else { return }
        restartingSignature = nil
    }

    public mutating func reset() {
        confirmedSignature = nil
        pendingSignature = nil
        restartingSignature = nil
    }
}
