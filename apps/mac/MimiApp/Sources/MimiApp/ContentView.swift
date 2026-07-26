import AppKit
import MimiAppCore
import SwiftUI

struct ContentView: View {
    @StateObject private var model = SetupViewModel()
    @AppStorage("mimiSetupDisplayLanguage") private var displayLanguageCode = SetupDisplayLanguage.releaseDefault.rawValue
    @State private var didCopyKeychainItemName = false

    private var displayLanguage: SetupDisplayLanguage {
        SetupDisplayLanguage(rawValue: displayLanguageCode) ?? .releaseDefault
    }

    private var copy: SetupWizardCopy {
        OnboardingCopy.copy(for: displayLanguage)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.06, green: 0.14, blue: 0.20).opacity(0.18),
                    Color(red: 0.07, green: 0.48, blue: 0.58).opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Divider()
                    .opacity(0.35)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header
                            providerPanel
                            keyPanel
                                .id("google-key-step")
                            helperPanel
                                .id("chrome-setup-step")
                            finalPanel
                            safetyLimitPanel
                        }
                        .padding(30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear {
                        scrollToChromeSetupIfReady(proxy)
                    }
                    .onChange(of: model.isGoogleKeyConfigured) { isReady in
                        guard isReady else { return }
                        withAnimation { proxy.scrollTo("chrome-setup-step", anchor: .top) }
                    }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                MimiMark(iconURL: model.brandIconURL, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mimi Setup for Chrome")
                        .font(.title3.weight(.semibold))
                    Text(copy.sidebarSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 8) {
                ForEach(model.rows) { row in
                    SetupRowView(row: row, copy: copy)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text(copy.currentStatusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.message.localized(copy))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(24)
        .frame(width: 274)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.09, blue: 0.16).opacity(0.95),
                    Color(red: 0.05, green: 0.18, blue: 0.24).opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .colorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            MimiMark(iconURL: model.brandIconURL, size: 62)
            VStack(alignment: .leading, spacing: 8) {
                Text(copy.headerTitle)
                    .font(.system(size: 30, weight: .semibold))
                Text(copy.setupSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Picker(copy.languageControlLabel, selection: displayLanguageBinding) {
                Text(copy.japaneseLanguageName).tag(SetupDisplayLanguage.japanese)
                Text(copy.englishLanguageName).tag(SetupDisplayLanguage.english)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            StatusPill(text: model.isRunning ? copy.statusRunning : model.message.localized(copy))
        }
    }

    private var keyPanel: some View {
        let state = model.state(for: .googleKey)
        return SetupPanel(step: 1, state: state, stateText: copy.title(for: state), title: copy.apiKeyTitle, systemImage: "key.fill") {
            if model.isGoogleKeyConfigured && model.credentialInput.isEmpty {
                Label(copy.googleKeyReady, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                keychainHelp
                DisclosureGroup(copy.changeGoogleKey) {
                    keySetupContent
                        .padding(.top, 10)
                }
                .font(.callout)
            } else {
                keySetupContent
                keychainHelp
            }
        }
    }

    private var providerPanel: some View {
        SetupPanel(title: copy.providerPanelTitle, systemImage: "waveform.and.mic") {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy.providerPanelExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    providerChoice(
                        provider: .gemini,
                        title: copy.providerGeminiLabel,
                        badge: copy.providerGeminiBadge,
                        description: copy.providerGeminiDescription,
                        accent: .cyan
                    )
                    providerChoice(
                        provider: .openai,
                        title: copy.providerOpenAILabel,
                        badge: copy.providerOpenAIBadge,
                        description: copy.providerOpenAIDescription,
                        accent: .purple
                    )
                }

                if model.isProviderSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(copy.providerSaving)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if model.activeSessionCount > 0 {
                    Label(copy.providerActiveSessionWarning, systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func providerChoice(
        provider: MimiProvider,
        title: String,
        badge: String,
        description: String,
        accent: Color
    ) -> some View {
        let isSelected = model.preferredProvider == provider
        return Button {
            model.selectProvider(provider)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.14), in: Capsule())
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.55))
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.11) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.9) : Color.secondary.opacity(0.22), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canChangeProvider)
        .accessibilityLabel("\(title), \(badge)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var keychainHelp: some View {
        KeychainHelpView(
            copy: copy,
            itemName: model.keychainItemName,
            account: model.keychainAccount,
            didCopyItemName: didCopyKeychainItemName,
            openAction: model.openKeychainAccess,
            copyAction: {
                model.copyKeychainItemName()
                didCopyKeychainItemName = true
            }
        )
    }

    private var keySetupContent: some View {
        VStack(alignment: .leading, spacing: 12) {
                Text(copy.apiKeyExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.accountGuidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.paidPathGuidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.guidedKeySteps)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.replaceKeyGuidance)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(copy.apiKeyPlaceholder, text: $model.credentialInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isRunning)
                HStack(spacing: 10) {
                    Button(action: model.openAIStudioFirstRun) {
                        Label(copy.openAIStudioFirstRun, systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    Button(action: model.openAIStudioAPIKeys) {
                        Label(copy.openAIStudioAPIKeys, systemImage: "key")
                    }
                    .buttonStyle(.bordered)
                    Button(action: model.saveKeyAndTest) {
                        Label(copy.saveAndTest, systemImage: "checkmark.shield")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.credentialInput.isEmpty || model.isRunning)
                }
                Text(copy.trustExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safetyLimitPanel: some View {
        SetupPanel(badge: copy.optionalSettingsLabel, title: copy.safetyPanelTitle, systemImage: "timer") {
            VStack(alignment: .leading, spacing: 14) {
                SafetyMeter(
                    monthlyLimitEnabled: model.monthlyLimitEnabled,
                    usedMinutes: model.safetyUsedMinutes,
                    limitMinutes: model.safetyLimitMinutes,
                    remainingMinutes: model.safetyRemainingMinutes,
                    copy: copy
                )

                Toggle(copy.safetyToggleTitle, isOn: $model.monthlyLimitEnabled)
                    .font(.callout.weight(.medium))
                    .disabled(model.isRunning)

                HStack(alignment: .center, spacing: 12) {
                    Text(copy.paidKeyLimitFieldLabel)
                        .font(.callout.weight(.medium))
                    TextField("30", text: $model.safetyLimitInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 78)
                        .disabled(model.isRunning || !model.monthlyLimitEnabled)
                    Stepper(
                        copy.safetyStepperLabel,
                        onIncrement: { model.adjustSafetyLimit(by: 5) },
                        onDecrement: { model.adjustSafetyLimit(by: -5) }
                    )
                    .labelsHidden()
                    .disabled(model.isRunning || !model.monthlyLimitEnabled)
                    Text(copy.minutesPerMonth)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button(action: model.saveLimitAndRestartServer) {
                        Label(copy.saveLimitAndRestart, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.safetyLimitInput.isEmpty || model.isRunning)
                    Button(action: model.resetUsageCounter) {
                        Label(copy.resetUsageCounter, systemImage: "counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRunning)
                }

                Text(copy.safetyExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var helperPanel: some View {
        ChromeSetupPanel(copy: copy, model: model)
    }

    private var finalPanel: some View {
        let state = model.state(for: .startListening)
        return SetupPanel(step: 3, state: state, stateText: copy.title(for: state), title: copy.finalPanelTitle, systemImage: "play.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                InstructionLine(text: copy.finalStepOne, tint: state.tint)
                InstructionLine(text: copy.finalStepTwo, tint: state.tint)
                InstructionLine(text: copy.finalStepThree, tint: state.tint)
            }
        }
    }

    private var displayLanguageBinding: Binding<SetupDisplayLanguage> {
        Binding(
            get: { displayLanguage },
            set: { displayLanguageCode = $0.rawValue }
        )
    }

    private func scrollToChromeSetupIfReady(_ proxy: ScrollViewProxy) {
        guard model.isGoogleKeyConfigured, !model.isChromeConnectionReady else { return }
        DispatchQueue.main.async {
            proxy.scrollTo("chrome-setup-step", anchor: .top)
        }
    }
}

private struct SafetyMeter: View {
    let monthlyLimitEnabled: Bool
    let usedMinutes: Double
    let limitMinutes: Double
    let remainingMinutes: Double
    let copy: SetupWizardCopy

    private var ratio: Double {
        guard limitMinutes > 0 else { return 0 }
        return min(1, max(0, usedMinutes / limitMinutes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(monthlyLimitEnabled ? "\(copy.remainingMinutesPrefix) \(format(remainingMinutes)) \(copy.remainingMinutesSuffix)" : copy.noMonthlyProtectionTitle)
                        .font(.title3.weight(.semibold))
                    Text(monthlyLimitEnabled ? "\(copy.usedThisMonthPrefix) \(format(usedMinutes)) \(copy.usedThisMonthSeparator) \(format(limitMinutes)) \(copy.usedThisMonthSuffix)" : copy.freeKeyNoMonthlyLimit)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((1 - ratio) * 100))%")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.13, green: 0.48, blue: 1.0), Color(red: 0.22, green: 0.82, blue: 0.91)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geometry.size.width * ratio))
                }
            }
            .frame(height: 9)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func format(_ minutes: Double) -> String {
        if minutes.rounded() == minutes {
            return String(Int(minutes))
        }
        return String(format: "%.1f", minutes)
    }
}

private struct StatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.15, green: 0.52, blue: 1.0), Color(red: 0.22, green: 0.80, blue: 0.88)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(Capsule())
    }
}

private struct InstructionLine: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension SetupState {
    var tint: Color {
        switch self {
        case .notStarted:
            .secondary
        case .running:
            .blue
        case .done:
            .green
        case .needsAttention:
            .orange
        case .ready:
            .blue
        }
    }
}

private extension SetupStatusMessage {
    func localized(_ copy: SetupWizardCopy) -> String {
        switch self {
        case .ready:
            copy.messageReady
        case .running:
            copy.statusRunning
        case .repoMissing:
            copy.messageRepoMissing
        case .extensionPathCopied:
            copy.messageExtensionPathCopied
        case .extensionPathCopyFailed:
            copy.messageExtensionPathCopyFailed
        case .saveLimitSuccess:
            copy.messageSaveLimitSuccess
        case .resetUsageSuccess:
            copy.messageResetUsageSuccess
        case .saveKeySuccess:
            copy.messageSaveKeySuccess
        case .helperSuccess:
            copy.messageHelperSuccess
        case .serverSuccess:
            copy.messageServerSuccess
        case .chromeSetupSuccess:
            copy.messageChromeSetupSuccess
        case .chromeSetupOpening:
            copy.messageChromeSetupOpening
        case .chromeInstallPending:
            copy.messageChromeInstallPending
        case .chromePinRequired:
            copy.messageChromePinRequired
        case .chromeSetupFailed:
            copy.messageChromeSetupFailed
        case .chromeSetupOpenFailed(let detail):
            if let detail, !detail.isEmpty {
                "\(copy.messageChromeSetupOpenFailed) \(detail)"
            } else {
                copy.messageChromeSetupOpenFailed
            }
        case .readyForChrome:
            copy.messageReadyForChrome
        case .needsAttention:
            copy.messageNeedsAttention
        case .custom(let value):
            value
        }
    }
}

extension SetupWizardCopy {
    func title(for rowKind: SetupRowKind) -> String {
        switch rowKind {
        case .googleKey:
            rowGoogleKey
        case .chromeConnection:
            rowChromeConnection
        case .startListening:
            rowStartListening
        }
    }

    func title(for state: SetupState) -> String {
        switch state {
        case .notStarted:
            stateNotStarted
        case .running:
            stateRunning
        case .done:
            stateDone
        case .needsAttention:
            stateNeedsAttention
        case .ready:
            stateReady
        }
    }
}
