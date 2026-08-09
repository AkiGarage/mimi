import Foundation

public enum MimiDisplayLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case japanese = "ja"
    case english = "en"

    public static let storageKey = "mimi.interface-language"
    public static let defaultValue = MimiDisplayLanguage.system

    public var id: String { rawValue }

    public static func normalized(_ rawValue: String?) -> MimiDisplayLanguage {
        rawValue.flatMap(MimiDisplayLanguage.init(rawValue:)) ?? defaultValue
    }

    public func locale(systemIdentifier: String) -> Locale {
        switch self {
        case .system:
            Locale(identifier: systemIdentifier)
        case .japanese:
            Locale(identifier: "ja")
        case .english:
            Locale(identifier: "en")
        }
    }
}

public enum MimiLocalizationKey: String, CaseIterable, Sendable {
    case commonDone = "common.done"
    case commonClose = "common.close"
    case commonDelete = "common.delete"
    case menuBarOpenWindow = "menu_bar.open_window"
    case menuBarQuit = "menu_bar.quit"

    case settingsTitle = "settings.title"
    case settingsDisplayLanguage = "settings.display_language"
    case settingsDisplayLanguageSystem = "settings.display_language.system"
    case settingsDisplayLanguageJapanese = "settings.display_language.japanese"
    case settingsDisplayLanguageEnglish = "settings.display_language.english"
    case settingsDisplayLanguageHelp = "settings.display_language.help"
    case settingsAPIKey = "settings.api_key"
    case settingsAPIKeySaved = "settings.api_key.saved"
    case settingsAPIKeyMissing = "settings.api_key.missing"
    case settingsAPIKeyNew = "settings.api_key.new"
    case settingsAPIKeyReplaceAccessibility = "settings.api_key.replace_accessibility"
    case settingsAPIKeySave = "settings.api_key.save"
    case settingsAPIKeyReplace = "settings.api_key.replace"
    case settingsAPIKeyDelete = "settings.api_key.delete"
    case settingsAPIKeyPrivacy = "settings.api_key.privacy"
    case settingsAutoStop = "settings.auto_stop"
    case settingsAutoStopDuration = "settings.auto_stop.duration"
    case settingsAutoStopHelp = "settings.auto_stop.help"
    case settingsPlaybackSpeed = "settings.playback_speed"
    case settingsPlaybackSpeedPicker = "settings.playback_speed.picker"
    case settingsPlaybackSpeedHelp = "settings.playback_speed.help"
    case settingsPaidGuard = "settings.paid_guard"
    case settingsPaidGuardEnabled = "settings.paid_guard.enabled"
    case settingsPaidGuardHint = "settings.paid_guard.hint"
    case settingsPaidGuardMonthlyLimit = "settings.paid_guard.monthly_limit"
    case settingsPaidGuardHelp = "settings.paid_guard.help"
    case settingsPermissions = "settings.permissions"
    case settingsPermissionsHelp = "settings.permissions.help"
    case settingsPermissionsOpen = "settings.permissions.open"
    case minutesValue = "minutes.value"

    case mainTagline = "main.tagline"
    case themePicker = "theme.picker"
    case themeLight = "theme.light"
    case themeDark = "theme.dark"
    case themeHelp = "theme.help"
    case settingsAccessibility = "settings.accessibility"
    case targetLanguageTitle = "target_language.title"
    case targetLanguageSubtitle = "target_language.subtitle"
    case targetLanguagePicker = "target_language.picker"
    case errorPrivacy = "error.privacy"
    case statusAccessibility = "status.accessibility"
    case sourceTitle = "source.title"
    case sourceManual = "source.manual"
    case sourceManualAccessibility = "source.manual.accessibility"
    case audioOriginal = "audio.original"
    case audioTranslatedFormat = "audio.translated.format"
    case audioAutoStop = "audio.auto_stop"
    case audioAutoStopAccessibility = "audio.auto_stop.accessibility"
    case audioAppAdjustment = "audio.app_adjustment"
    case audioSwitchFormat = "audio.switch.format"
    case audioSwitchStop = "audio.switch.stop"
    case volumePercentAccessibility = "volume.percent.accessibility"
    case privacyTitle = "privacy.title"
    case privacyMessage = "privacy.message"
    case listeningStopHint = "listening.stop_hint"

    case sourcePickerTitle = "source_picker.title"
    case sourcePickerSubtitle = "source_picker.subtitle"
    case sourcePickerSearching = "source_picker.searching"
    case sourcePickerEmptyTitle = "source_picker.empty.title"
    case sourcePickerEmptyMessage = "source_picker.empty.message"
    case sourcePickerSearchPrompt = "source_picker.search_prompt"
    case sourcePickerGuidanceTitle = "source_picker.guidance.title"
    case sourcePickerGuidanceMessage = "source_picker.guidance.message"
    case sourcePickerRecommended = "source_picker.recommended"
    case sourcePickerOthers = "source_picker.others"
    case sourcePickerResults = "source_picker.results"
    case sourcePickerOpenSettings = "source_picker.open_settings"
    case sourcePickerApplicationSubtitle = "source_picker.application.subtitle"
    case sourcePickerSelected = "source_picker.selected"

    case errorCredentialTitle = "error.credential.title"
    case errorCredentialMessage = "error.credential.message"
    case errorPermissionTitle = "error.permission.title"
    case errorPermissionMessage = "error.permission.message"
    case errorNetworkTitle = "error.network.title"
    case errorNetworkMessage = "error.network.message"
    case errorQuotaTitle = "error.quota.title"
    case errorQuotaMessage = "error.quota.message"
    case errorBillingTitle = "error.billing.title"
    case errorBillingMessage = "error.billing.message"
    case errorNoAudioTitle = "error.no_audio.title"
    case errorNoAudioMessage = "error.no_audio.message"
    case errorMultipleAudioTitle = "error.multiple_audio.title"
    case errorMultipleAudioMessage = "error.multiple_audio.message"
    case errorUnknownTitle = "error.unknown.title"
    case errorUnknownMessage = "error.unknown.message"

    case stateNeedsSetupTitle = "state.needs_setup.title"
    case stateNeedsSetupMessage = "state.needs_setup.message"
    case stateIdleNoSourceTitle = "state.idle_no_source.title"
    case stateIdleNoSourceMessage = "state.idle_no_source.message"
    case stateIdleReadyTitle = "state.idle_ready.title"
    case stateIdleReadyMessage = "state.idle_ready.message"
    case stateDetectingSourceTitle = "state.detecting_source.title"
    case stateDetectingSourceMessage = "state.detecting_source.message"
    case stateRequestingPermissionTitle = "state.requesting_permission.title"
    case stateRequestingPermissionMessage = "state.requesting_permission.message"
    case stateConnectingTitle = "state.connecting.title"
    case stateConnectingMessage = "state.connecting.message"
    case stateListeningTitle = "state.listening.title"
    case stateListeningMessage = "state.listening.message"
    case stateReconnectingTitle = "state.reconnecting.title"
    case stateReconnectingMessage = "state.reconnecting.message"
    case stateStoppingTitle = "state.stopping.title"
    case stateStoppingMessage = "state.stopping.message"
    case stateSourceEndedTitle = "state.source_ended.title"
    case stateSourceEndedMessage = "state.source_ended.message"
    case stateAutoStopReachedTitle = "state.auto_stop_reached.title"
    case stateAutoStopReachedMessage = "state.auto_stop_reached.message"
    case statePaidLimitReachedTitle = "state.paid_limit_reached.title"
    case statePaidLimitReachedMessage = "state.paid_limit_reached.message"

    case sourceDefaultName = "source.default_name"
    case sourcePlaceholder = "source.placeholder"
    case sourcePrevious = "source.previous"
    case sourceTranslatingOne = "source.translating.one"
    case sourceTranslatingMultiple = "source.translating.multiple"
    case sourceBrowserUnknown = "source.browser.unknown"
    case sourceApplicationAudio = "source.application.audio"
    case sourceBrowserWindow = "source.browser.window"
    case sourceWindowOnly = "source.window.only"
    case sourceApplicationDetail = "source.application.detail"
    case sourceDisplay = "source.display"
    case sourceSystem = "source.system"

    case actionSetup = "action.setup"
    case actionStart = "action.start"
    case actionListenAgain = "action.listen_again"
    case actionShowSettings = "action.show_settings"
    case actionDetecting = "action.detecting"
    case actionStop = "action.stop"
    case actionOpenSettings = "action.open_settings"
    case actionStopping = "action.stopping"
}

public enum MimiLocalization {
    public static func string(_ key: MimiLocalizationKey, locale: Locale) -> String {
        localizedBundle(for: locale).localizedString(
            forKey: key.rawValue,
            value: key.rawValue,
            table: "Localizable"
        )
    }

    public static func formatted(
        _ key: MimiLocalizationKey,
        locale: Locale,
        _ arguments: CVarArg...
    ) -> String {
        String(format: string(key, locale: locale), locale: locale, arguments: arguments)
    }

    private static func localizedBundle(for locale: Locale) -> Bundle {
        let requestedLanguage = locale.language.languageCode?.identifier
        let language = requestedLanguage == "ja" ? "ja" : "en"
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .module }
        return bundle
    }
}
