import MimiForMac
import SwiftUI

struct MimiSettingsView: View {
    @ObservedObject var model: MimiForMacViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage(MimiDisplayLanguage.storageKey) private var displayLanguageRawValue =
        MimiDisplayLanguage.defaultValue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(localized(.settingsTitle))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(localized(.commonDone)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                Section(localized(.settingsDisplayLanguage)) {
                    Picker(localized(.settingsDisplayLanguage), selection: $displayLanguageRawValue) {
                        ForEach(MimiDisplayLanguage.allCases) { language in
                            Text(displayLanguageName(language))
                                .tag(language.rawValue)
                        }
                    }
                    Text(localized(.settingsDisplayLanguageHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(localized(.settingsAPIKey)) {
                    HStack {
                        Label(
                            model.hasCredential
                                ? localized(.settingsAPIKeySaved)
                                : localized(.settingsAPIKeyMissing),
                            systemImage: model.hasCredential ? "checkmark.shield" : "key"
                        )
                            .foregroundStyle(model.hasCredential ? .green : .secondary)
                        Spacer()
                    }
                    SecureField(localized(.settingsAPIKeyNew), text: $model.keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(
                            model.hasCredential
                                ? localized(.settingsAPIKeyReplaceAccessibility)
                                : "Gemini API key"
                        )
                    HStack {
                        Button(
                            model.hasCredential
                                ? localized(.settingsAPIKeyReplace)
                                : localized(.settingsAPIKeySave)
                        ) {
                            model.saveKey()
                        }
                        .buttonStyle(.borderedProminent)
                        if model.hasCredential {
                            Button(localized(.commonDelete), role: .destructive) { model.deleteKey() }
                                .accessibilityLabel(localized(.settingsAPIKeyDelete))
                        }
                    }
                    Text(localized(.settingsAPIKeyPrivacy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(localized(.settingsAutoStop)) {
                    Stepper(value: $model.autoStopMinutes, in: AutoStopTimer.minimumLimitMinutes...AutoStopTimer.maximumLimitMinutes) {
                        LabeledContent(
                            localized(.settingsAutoStopDuration),
                            value: MimiLocalization.formatted(
                                .minutesValue,
                                locale: locale,
                                model.autoStopMinutes
                            )
                        )
                    }
                    Text(localized(.settingsAutoStopHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(localized(.settingsPlaybackSpeed)) {
                    Picker(localized(.settingsPlaybackSpeedPicker), selection: $model.playbackRate) {
                        ForEach(MimiPlaybackRate.supported, id: \.self) { rate in
                            Text(playbackRateLabel(rate)).tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(localized(.settingsPlaybackSpeedHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(localized(.settingsPaidGuard)) {
                    Toggle(localized(.settingsPaidGuardEnabled), isOn: $model.paidProtectionEnabled)
                        .accessibilityHint(localized(.settingsPaidGuardHint))
                    if model.paidProtectionEnabled {
                        Stepper(value: $model.paidLimitMinutes, in: 1...120) {
                            LabeledContent(
                                localized(.settingsPaidGuardMonthlyLimit),
                                value: MimiLocalization.formatted(
                                    .minutesValue,
                                    locale: locale,
                                    model.paidLimitMinutes
                                )
                            )
                        }
                        Text(localized(.settingsPaidGuardHelp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(localized(.settingsPermissions)) {
                    Text(localized(.settingsPermissionsHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(localized(.settingsPermissionsOpen)) {
                        model.openSystemAudioSettings()
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(width: 500, height: 650)
        .onDisappear { model.clearKeyDraft() }
    }

    private func localized(_ key: MimiLocalizationKey) -> String {
        MimiLocalization.string(key, locale: locale)
    }

    private func displayLanguageName(_ language: MimiDisplayLanguage) -> String {
        switch language {
        case .system:
            localized(.settingsDisplayLanguageSystem)
        case .japanese:
            localized(.settingsDisplayLanguageJapanese)
        case .english:
            localized(.settingsDisplayLanguageEnglish)
        }
    }

    private func playbackRateLabel(_ rate: Double) -> String {
        switch MimiPlaybackRate.normalized(rate) {
        case 1.25: "1.25×"
        case 1.5: "1.5×"
        case 1.75: "1.75×"
        case 2: "2×"
        default: "1×"
        }
    }
}
