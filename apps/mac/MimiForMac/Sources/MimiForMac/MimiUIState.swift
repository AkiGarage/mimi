import Foundation

public enum MimiUIError: Equatable, Sendable {
    case credential
    case permission
    case network
    case quota
    case billing
    case noAudio
    case multipleAudio
    case unknown

    public func title(locale: Locale) -> String {
        let key: MimiLocalizationKey = switch self {
        case .credential: .errorCredentialTitle
        case .permission: .errorPermissionTitle
        case .network: .errorNetworkTitle
        case .quota: .errorQuotaTitle
        case .billing: .errorBillingTitle
        case .noAudio: .errorNoAudioTitle
        case .multipleAudio: .errorMultipleAudioTitle
        case .unknown: .errorUnknownTitle
        }
        return MimiLocalization.string(key, locale: locale)
    }

    public func message(locale: Locale) -> String {
        let key: MimiLocalizationKey = switch self {
        case .credential: .errorCredentialMessage
        case .permission: .errorPermissionMessage
        case .network: .errorNetworkMessage
        case .quota: .errorQuotaMessage
        case .billing: .errorBillingMessage
        case .noAudio: .errorNoAudioMessage
        case .multipleAudio: .errorMultipleAudioMessage
        case .unknown: .errorUnknownMessage
        }
        return MimiLocalization.string(key, locale: locale)
    }

    public var symbolName: String {
        switch self {
        case .credential: "key.fill"
        case .permission: "lock.trianglebadge.exclamationmark"
        case .network: "wifi.exclamationmark"
        case .quota, .billing: "hourglass"
        case .noAudio: "waveform.slash"
        case .multipleAudio: "waveform.badge.exclamationmark"
        case .unknown: "exclamationmark.triangle"
        }
    }
}

public enum MimiUIState: Equatable, Sendable {
    case needsSetup
    case idleNoSource
    case idleReady
    case detectingSource
    case requestingPermission
    case connecting
    case listening
    case reconnecting
    case stopping
    case sourceEnded
    case autoStopReached
    case paidLimitReached
    case error(MimiUIError)

    public func title(locale: Locale) -> String {
        let key: MimiLocalizationKey
        switch self {
        case .needsSetup: key = .stateNeedsSetupTitle
        case .idleNoSource: key = .stateIdleNoSourceTitle
        case .idleReady: key = .stateIdleReadyTitle
        case .detectingSource: key = .stateDetectingSourceTitle
        case .requestingPermission: key = .stateRequestingPermissionTitle
        case .connecting: key = .stateConnectingTitle
        case .listening: key = .stateListeningTitle
        case .reconnecting: key = .stateReconnectingTitle
        case .stopping: key = .stateStoppingTitle
        case .sourceEnded: key = .stateSourceEndedTitle
        case .autoStopReached: key = .stateAutoStopReachedTitle
        case .paidLimitReached: key = .statePaidLimitReachedTitle
        case .error(let error): return error.title(locale: locale)
        }
        return MimiLocalization.string(key, locale: locale)
    }

    public func message(locale: Locale) -> String {
        let key: MimiLocalizationKey
        switch self {
        case .needsSetup: key = .stateNeedsSetupMessage
        case .idleNoSource: key = .stateIdleNoSourceMessage
        case .idleReady: key = .stateIdleReadyMessage
        case .detectingSource: key = .stateDetectingSourceMessage
        case .requestingPermission: key = .stateRequestingPermissionMessage
        case .connecting: key = .stateConnectingMessage
        case .listening: key = .stateListeningMessage
        case .reconnecting: key = .stateReconnectingMessage
        case .stopping: key = .stateStoppingMessage
        case .sourceEnded: key = .stateSourceEndedMessage
        case .autoStopReached: key = .stateAutoStopReachedMessage
        case .paidLimitReached: key = .statePaidLimitReachedMessage
        case .error(let error): return error.message(locale: locale)
        }
        return MimiLocalization.string(key, locale: locale)
    }

    public var symbolName: String {
        switch self {
        case .needsSetup: "sparkles"
        case .idleNoSource: "rectangle.stack.badge.plus"
        case .idleReady: "checkmark.circle"
        case .detectingSource: "waveform.badge.magnifyingglass"
        case .requestingPermission: "lock.trianglebadge.exclamationmark"
        case .connecting: "ellipsis.circle"
        case .listening: "waveform"
        case .reconnecting: "arrow.triangle.2.circlepath"
        case .stopping: "stop.circle"
        case .sourceEnded: "rectangle.on.rectangle.slash"
        case .autoStopReached: "clock.badge.checkmark"
        case .paidLimitReached: "hourglass"
        case .error(let error): error.symbolName
        }
    }

    public var isActive: Bool {
        switch self {
        case .detectingSource, .connecting, .listening, .reconnecting, .stopping: true
        default: false
        }
    }

    public var isRecoverableByRetry: Bool {
        switch self {
        case .error(.permission), .error(.credential), .error(.billing), .paidLimitReached: false
        default: true
        }
    }
}
