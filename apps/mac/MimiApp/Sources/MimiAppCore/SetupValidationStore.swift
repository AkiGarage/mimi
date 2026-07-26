import Foundation

public struct SetupValidationStore {
    private static let googleKeyValidatedKey = "MimiGoogleKeyConnectionValidated"
    private static let listeningStartedKey = "MimiListeningStarted"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func isGoogleKeyValidated(hasKey: Bool) -> Bool {
        hasKey && defaults.bool(forKey: Self.googleKeyValidatedKey)
    }

    public func markGoogleKeyValidated(_ validated: Bool) {
        defaults.set(validated, forKey: Self.googleKeyValidatedKey)
    }

    public func isListeningStarted() -> Bool {
        defaults.bool(forKey: Self.listeningStartedKey)
    }

    public func markListeningStarted(_ started: Bool) {
        defaults.set(started, forKey: Self.listeningStartedKey)
    }
}
