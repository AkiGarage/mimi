import AppKit
import MimiForMac
import SwiftUI

struct MimiMainView: View {
    @ObservedObject var model: MimiForMacViewModel
    @Environment(\.locale) private var locale
    @AppStorage("mimi.appearance") private var appearance = MimiAppearance.dark.rawValue

    private var selectedAppearance: MimiAppearance {
        MimiAppearance(rawValue: appearance) ?? .dark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusCard
            targetLanguageCard
            sourceCard
            if model.state == .needsSetup {
                privacyNote
            } else {
                listeningControls
                    .mimiPanel(appearance: selectedAppearance)
            }
            footer
        }
        .padding(18)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            brandBackground
                .ignoresSafeArea()
        }
        .preferredColorScheme(selectedAppearance.colorScheme)
        .tint(Color(red: 0.09, green: 0.67, blue: 0.96))
        .sheet(isPresented: $model.isSourcePickerPresented) {
            MimiSourcePickerView(model: model)
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            MimiSettingsView(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            MimiAppIcon()
            VStack(alignment: .leading, spacing: 3) {
                Text("Mimi for Mac")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(localized(.mainTagline))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 3) {
                appearanceButton(
                    .light,
                    symbol: "sun.max.fill",
                    accessibilityLabel: localized(.themeLight)
                )
                appearanceButton(
                    .dark,
                    symbol: "moon.stars.fill",
                    accessibilityLabel: localized(.themeDark)
                )
            }
            .padding(3)
            .background(selectedAppearance.controlFill, in: Capsule())
            .overlay(Capsule().stroke(selectedAppearance.controlBorder, lineWidth: 1))
            .help(localized(.themeHelp))
            Button {
                model.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(selectedAppearance.controlFill, in: Circle())
            .overlay(Circle().stroke(selectedAppearance.controlBorder))
            .shadow(color: selectedAppearance.controlShadow, radius: 7, y: 3)
            .accessibilityLabel(localized(.settingsAccessibility))
        }
        .padding(.bottom, 2)
    }

    private func appearanceButton(
        _ value: MimiAppearance,
        symbol: String,
        accessibilityLabel: String
    ) -> some View {
        let isSelected = selectedAppearance == value
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                appearance = value.rawValue
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    isSelected
                        ? selectedAppearance.themeIconColor(for: value)
                        : Color.secondary
                )
                .frame(width: 28, height: 26)
                .background(
                    isSelected
                        ? selectedAppearance.themeSelectionFill(for: value)
                        : Color.clear,
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var targetLanguageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(localized(.targetLanguageTitle), systemImage: "headphones")
                        .font(.body.weight(.bold))
                    Text(localized(.targetLanguageSubtitle))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)

                Image(systemName: "sparkles")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(selectedAppearance.heroSparkle)
                    .offset(y: -4)
                    .accessibilityHidden(true)
            }

            Menu {
                Picker(localized(.targetLanguagePicker), selection: $model.targetLanguageCode) {
                    ForEach(model.targetLanguages(in: locale)) { language in
                        Text(language.displayName(in: locale))
                            .tag(language.code)
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                                .fill(selectedAppearance.languageOrbFill)
                            Image(systemName: "globe.asia.australia.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(selectedAppearance.accent)
                        }
                        .frame(width: 40, height: 40)
                        Text(targetLanguageDisplayName)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .layoutPriority(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(selectedAppearance.accent)
                            .frame(width: 28, height: 28)
                            .background(selectedAppearance.languageOrbFill, in: Circle())
                    }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .disabled(model.state.isActive)
            .accessibilityLabel(localized(.targetLanguagePicker))
            .accessibilityValue(targetLanguageDisplayName)
        }
        .padding(.trailing, 4)
        .mimiHeroPanel(appearance: selectedAppearance)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: model.state.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(model.statusColor)
                    .frame(width: 38, height: 38)
                    .background(model.statusColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(stateTitle)
                        .font(.headline)
                        .foregroundStyle(model.statusColor)
                    Text(stateMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if case .error = model.state {
                Text(localized(.errorPrivacy))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .mimiPanel(accent: model.statusColor, appearance: selectedAppearance)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(localized(.statusAccessibility))
        .accessibilityValue("\(stateTitle). \(stateMessage)")
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localized(.sourceTitle), systemImage: "dot.radiowaves.left.and.right")
                .font(.body.weight(.bold))
                .foregroundStyle(.primary.opacity(0.82))
            HStack(spacing: 10) {
                TranslationTargetIcon(source: model.selectedSource, fallbackSymbol: sourceSymbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedSourceName(locale: locale))
                        .lineLimit(1)
                    Text(model.selectedSourceSubtitle(locale: locale))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if model.showsManualSourceControl {
                    Button(localized(.sourceManual)) {
                        model.presentSourcePicker()
                    }
                        .buttonStyle(.borderless)
                        .disabled(model.state.isActive)
                        .accessibilityLabel(localized(.sourceManualAccessibility))
                }
            }
        }
        .mimiPanel(appearance: selectedAppearance)
        .accessibilityElement(children: .contain)
    }

    private var listeningControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.canControlOriginalVolume {
                volumeControl(
                    title: localized(.audioOriginal),
                    value: $model.originalVolume,
                    enabled: true
                )
            } else if let applicationName = model.originalVolumeControllableAlternativeName {
                originalVolumeSwitchControl(applicationName: applicationName)
            }
            volumeControl(
                title: MimiLocalization.formatted(
                    .audioTranslatedFormat,
                    locale: locale,
                    targetLanguageDisplayName
                ),
                value: $model.translatedVolume,
                enabled: true
            )
            HStack {
                Label(localized(.audioAutoStop), systemImage: "clock")
                Spacer()
                Text(model.remainingTimeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(localized(.audioAutoStopAccessibility))
            .accessibilityValue(model.remainingTimeText)
        }
    }

    private func originalVolumeSwitchControl(applicationName: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(localized(.audioOriginal))
                Spacer()
                Text(localized(.audioAppAdjustment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.switchToOriginalVolumeControllableSource()
            } label: {
                Label(
                    MimiLocalization.formatted(
                        .audioSwitchFormat,
                        locale: locale,
                        applicationName
                    ),
                    systemImage: "speaker.wave.2"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.state.isActive)
            if model.state.isActive {
                Text(localized(.audioSwitchStop))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func volumeControl(
        title: String,
        value: Binding<Double>,
        enabled: Bool
    ) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
                .tint(selectedAppearance.accent)
                .disabled(!enabled)
                .accessibilityLabel(title)
                .accessibilityValue(
                    MimiLocalization.formatted(
                        .volumePercentAccessibility,
                        locale: locale,
                        Int(value.wrappedValue * 100)
                    )
                )
        }
    }

    private var sourceSymbol: String {
        switch model.selectedSource?.kind {
        case .system: "speaker.wave.2"
        case .window: "macwindow"
        case .application: "app.fill"
        case .display: "display"
        case nil: "play.rectangle.on.rectangle"
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localized(.privacyTitle), systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(localized(.privacyMessage))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .mimiPanel(accent: .cyan, appearance: selectedAppearance)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                model.performPrimaryAction()
            } label: {
                Label(primaryActionTitle, systemImage: primaryActionSymbol)
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MimiPrimaryButtonStyle(appearance: selectedAppearance))
            .shadow(color: selectedAppearance.buttonShadow, radius: 12, y: 5)
            .disabled(model.state == .stopping || model.state == .detectingSource)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(primaryActionTitle)
            .accessibilityHint(stateMessage)

            if model.state.isActive {
                Text(localized(.listeningStopHint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var brandBackground: some View {
        ZStack {
            selectedAppearance.backgroundColor
            Circle()
                .fill(selectedAppearance.auraPrimary)
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: -175, y: -290)
            Circle()
                .fill(selectedAppearance.auraSecondary)
                .frame(width: 260, height: 260)
                .blur(radius: 75)
                .offset(x: 180, y: 265)
            LinearGradient(
                colors: selectedAppearance.backgroundWash,
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var stateTitle: String { model.state.title(locale: locale) }

    private var stateMessage: String { model.state.message(locale: locale) }

    private var targetLanguageDisplayName: String {
        model.targetLanguageDisplayName(in: locale)
    }

    private var primaryActionTitle: String {
        model.primaryActionTitle(locale: locale)
    }

    private var primaryActionSymbol: String {
        model.state.isActive ? "stop.fill" : "waveform"
    }

    private func localized(_ key: MimiLocalizationKey) -> String {
        MimiLocalization.string(key, locale: locale)
    }
}

private enum MimiAppearance: String {
    case light
    case dark

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var backgroundColor: Color {
        switch self {
        case .light: Color(red: 0.96, green: 0.98, blue: 1.00)
        case .dark: Color(red: 0.025, green: 0.055, blue: 0.12)
        }
    }

    var accent: Color {
        Color(red: 0.03, green: 0.64, blue: 0.96)
    }

    var backgroundWash: [Color] {
        switch self {
        case .light:
            [
                Color.white.opacity(0.12),
                Color(red: 0.89, green: 0.96, blue: 1.00).opacity(0.20),
                Color(red: 0.90, green: 1.00, blue: 0.98).opacity(0.16),
            ]
        case .dark:
            [
                Color(red: 0.02, green: 0.12, blue: 0.28).opacity(0.25),
                Color.clear,
                Color(red: 0.00, green: 0.20, blue: 0.23).opacity(0.16),
            ]
        }
    }

    var auraPrimary: Color {
        switch self {
        case .light: Color(red: 0.02, green: 0.55, blue: 1.00).opacity(0.26)
        case .dark: Color(red: 0.00, green: 0.43, blue: 1.00).opacity(0.34)
        }
    }

    var auraSecondary: Color {
        switch self {
        case .light: Color(red: 0.00, green: 0.82, blue: 0.68).opacity(0.20)
        case .dark: Color(red: 0.00, green: 0.79, blue: 0.67).opacity(0.23)
        }
    }

    var panelFill: Color {
        switch self {
        case .light: .white.opacity(0.78)
        case .dark: Color(red: 0.075, green: 0.115, blue: 0.20).opacity(0.86)
        }
    }

    var panelBorder: Color {
        switch self {
        case .light: Color(red: 0.08, green: 0.20, blue: 0.35).opacity(0.12)
        case .dark: .white.opacity(0.14)
        }
    }

    var controlFill: Color {
        switch self {
        case .light: .white.opacity(0.82)
        case .dark: .white.opacity(0.08)
        }
    }

    var controlBorder: Color {
        switch self {
        case .light: Color(red: 0.08, green: 0.20, blue: 0.35).opacity(0.13)
        case .dark: .white.opacity(0.14)
        }
    }

    var panelShadow: Color {
        switch self {
        case .light: Color(red: 0.02, green: 0.18, blue: 0.35).opacity(0.10)
        case .dark: .black.opacity(0.25)
        }
    }

    var controlShadow: Color {
        switch self {
        case .light: Color(red: 0.03, green: 0.24, blue: 0.42).opacity(0.10)
        case .dark: .black.opacity(0.22)
        }
    }

    var buttonShadow: Color { accent.opacity(self == .light ? 0.24 : 0.32) }

    var buttonGradient: [Color] {
        switch self {
        case .light:
            [
                Color(red: 0.02, green: 0.52, blue: 1.00),
                Color(red: 0.00, green: 0.75, blue: 0.69),
            ]
        case .dark:
            [
                Color(red: 0.04, green: 0.48, blue: 1.00),
                Color(red: 0.00, green: 0.68, blue: 0.64),
            ]
        }
    }

    var languageOrbFill: Color {
        switch self {
        case .light: .white.opacity(0.78)
        case .dark: .white.opacity(0.10)
        }
    }

    var heroSparkle: Color {
        switch self {
        case .light: Color(red: 0.00, green: 0.66, blue: 0.72).opacity(0.52)
        case .dark: Color(red: 0.31, green: 0.95, blue: 0.86).opacity(0.48)
        }
    }

    var heroGradient: [Color] {
        switch self {
        case .light:
            [
                Color(red: 0.72, green: 0.90, blue: 1.00).opacity(0.88),
                Color(red: 0.78, green: 0.98, blue: 0.93).opacity(0.72),
                .white.opacity(0.84),
            ]
        case .dark:
            [
                Color(red: 0.04, green: 0.30, blue: 0.58).opacity(0.82),
                Color(red: 0.02, green: 0.28, blue: 0.34).opacity(0.72),
                Color(red: 0.07, green: 0.11, blue: 0.20).opacity(0.92),
            ]
        }
    }

    func themeSelectionFill(for value: MimiAppearance) -> Color {
        switch value {
        case .light: Color(red: 1.00, green: 0.82, blue: 0.28).opacity(0.23)
        case .dark: Color(red: 0.31, green: 0.47, blue: 1.00).opacity(0.26)
        }
    }

    func themeIconColor(for value: MimiAppearance) -> Color {
        switch value {
        case .light: Color(red: 0.92, green: 0.56, blue: 0.03)
        case .dark: Color(red: 0.54, green: 0.68, blue: 1.00)
        }
    }
}

private struct TranslationTargetIcon: View {
    let source: AudioSource?
    let fallbackSymbol: String

    var body: some View {
        if let image = applicationIcon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .accessibilityHidden(true)
        }
    }

    private var applicationIcon: NSImage? {
        if let processID = source?.processID,
           let icon = NSRunningApplication(processIdentifier: processID)?.icon {
            return icon
        }
        guard let bundleIdentifier = source?.bundleIdentifier,
              let applicationURL = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: bundleIdentifier
              ) else { return nil }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}

private struct MimiAppIcon: View {
    var body: some View {
        Image(nsImage: sourceImage)
            .interpolation(.high)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private var sourceImage: NSImage {
        let image: NSImage
        if let url = Bundle.main.url(forResource: "MimiHeaderIcon", withExtension: "png"),
           let bundledImage = NSImage(contentsOf: url) {
            image = bundledImage
        } else {
            image = NSApplication.shared.applicationIconImage.copy() as? NSImage
                ?? NSApplication.shared.applicationIconImage
        }
        image.size = NSSize(width: 44, height: 44)
        return image
    }
}

private struct MimiPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let appearance: MimiAppearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: appearance.buttonGradient,
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    func mimiPanel(accent: Color? = nil, appearance: MimiAppearance) -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                appearance.panelFill,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        accent?.opacity(0.32) ?? appearance.panelBorder,
                        lineWidth: 1
                    )
            }
            .shadow(color: appearance.panelShadow, radius: 12, y: 6)
    }

    func mimiHeroPanel(appearance: MimiAppearance) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: appearance.heroGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(appearance.accent.opacity(0.26), lineWidth: 1)
            }
            .shadow(color: appearance.accent.opacity(0.15), radius: 16, y: 7)
    }
}
