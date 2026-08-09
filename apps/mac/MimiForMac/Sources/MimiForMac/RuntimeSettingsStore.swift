import Foundation

public struct MimiRuntimeSettings: Sendable, Equatable {
    public var autoStopMinutes: Int
    public var paidProtectionEnabled: Bool
    public var paidLimitMinutes: Int
    public var targetLanguageCode: String
    public var playbackRate: Double

    public init(
        autoStopMinutes: Int = AutoStopTimer.defaultLimitMinutes,
        paidProtectionEnabled: Bool = false,
        paidLimitMinutes: Int = PaidUsageGuard.defaultLimitMinutes,
        targetLanguageCode: String = MimiTargetLanguage.defaultCode,
        playbackRate: Double = MimiPlaybackRate.defaultValue
    ) {
        self.autoStopMinutes = AutoStopTimer.clampMinutes(autoStopMinutes)
        self.paidProtectionEnabled = paidProtectionEnabled
        self.paidLimitMinutes = max(1, paidLimitMinutes)
        self.targetLanguageCode = MimiTargetLanguage.normalizedCode(targetLanguageCode)
        self.playbackRate = MimiPlaybackRate.normalized(playbackRate)
    }
}

/// Persists only non-secret runtime preferences. Credentials remain exclusively
/// in Keychain and usage accounting remains in `PaidUsageGuard`'s own store.
public final class MimiRuntimeSettingsStore: @unchecked Sendable {
    private enum Key {
        static let configured = "mimi.runtime-settings.configured"
        static let autoStopMinutes = "mimi.runtime-settings.auto-stop-minutes"
        static let paidProtectionEnabled = "mimi.runtime-settings.paid-protection-enabled"
        static let paidLimitMinutes = "mimi.runtime-settings.paid-limit-minutes"
        static let targetLanguageCode = "mimi.runtime-settings.target-language-code"
        static let playbackRate = "mimi.runtime-settings.playback-rate"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MimiRuntimeSettings {
        guard defaults.bool(forKey: Key.configured) else { return MimiRuntimeSettings() }
        return MimiRuntimeSettings(
            autoStopMinutes: defaults.integer(forKey: Key.autoStopMinutes),
            paidProtectionEnabled: defaults.bool(forKey: Key.paidProtectionEnabled),
            paidLimitMinutes: defaults.integer(forKey: Key.paidLimitMinutes),
            targetLanguageCode: defaults.string(forKey: Key.targetLanguageCode)
                ?? MimiTargetLanguage.defaultCode,
            playbackRate: defaults.object(forKey: Key.playbackRate) == nil
                ? MimiPlaybackRate.defaultValue
                : defaults.double(forKey: Key.playbackRate)
        )
    }

    public func save(_ settings: MimiRuntimeSettings) {
        let normalized = MimiRuntimeSettings(
            autoStopMinutes: settings.autoStopMinutes,
            paidProtectionEnabled: settings.paidProtectionEnabled,
            paidLimitMinutes: settings.paidLimitMinutes,
            targetLanguageCode: settings.targetLanguageCode,
            playbackRate: settings.playbackRate
        )
        defaults.set(normalized.autoStopMinutes, forKey: Key.autoStopMinutes)
        defaults.set(normalized.paidProtectionEnabled, forKey: Key.paidProtectionEnabled)
        defaults.set(normalized.paidLimitMinutes, forKey: Key.paidLimitMinutes)
        defaults.set(normalized.targetLanguageCode, forKey: Key.targetLanguageCode)
        defaults.set(normalized.playbackRate, forKey: Key.playbackRate)
        defaults.set(true, forKey: Key.configured)
    }
}
