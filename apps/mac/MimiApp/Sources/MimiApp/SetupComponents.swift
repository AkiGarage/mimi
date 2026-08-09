import AppKit
import MimiAppCore
import SwiftUI

struct SetupPanel<Content: View>: View {
    let title: String
    let systemImage: String
    let step: Int?
    let state: SetupState?
    let stateText: String?
    let badge: String?
    let content: Content

    init(
        step: Int? = nil,
        state: SetupState? = nil,
        stateText: String? = nil,
        badge: String? = nil,
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.step = step
        self.state = state
        self.stateText = stateText
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let step {
                    StepBadge(number: step, state: state ?? .ready)
                } else {
                    Image(systemName: systemImage)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.10, green: 0.48, blue: 1.0), Color(red: 0.24, green: 0.82, blue: 0.92)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 28)
                }
                Text(title)
                    .font(.headline)
                if let state, let stateText {
                    Label(stateText, systemImage: state.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.tint)
                }
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45))
        }
        .shadow(color: .black.opacity(0.06), radius: 18, y: 10)
    }
}

struct StepBadge: View {
    let number: Int
    let state: SetupState

    var body: some View {
        Text("\(number)")
            .font(.callout.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(state.tint.gradient)
            .clipShape(Circle())
    }
}

struct KeychainHelpView: View {
    let copy: SetupWizardCopy
    let itemName: String
    let account: String
    let didCopyItemName: Bool
    let openAction: () -> Void
    let copyAction: () -> Void

    var body: some View {
        DisclosureGroup(copy.keychainHelpTitle) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent(copy.keychainLocationLabel) {
                    Text(copy.keychainLocationValue)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(copy.keychainItemNameLabel) {
                    Text(itemName)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent(copy.keychainAccountLabel) {
                    Text(account)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text(copy.keychainPasswordsAppNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: openAction) {
                        Label(copy.openKeychainAccess, systemImage: "key.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    Button(action: copyAction) {
                        Label(
                            didCopyItemName ? copy.copiedKeychainItemName : copy.copyKeychainItemName,
                            systemImage: didCopyItemName ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 10)
        }
        .font(.callout)
    }
}

struct SetupRowView: View {
    let row: SetupRow
    let copy: SetupWizardCopy

    var body: some View {
        HStack(spacing: 10) {
            Text("\(row.step)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(row.state.tint.gradient)
                .clipShape(Circle())
            Image(systemName: row.state.systemImage)
                .foregroundStyle(row.state.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title(for: row.kind))
                    .font(.callout.weight(.medium))
                Text(copy.title(for: row.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }
}

struct ChromeInstallGuideView: View {
    let copy: SetupWizardCopy
    let extensionFolderPath: String
    let hasStartedSetup: Bool
    let isPathCopied: Bool
    let isVerified: Bool
    let isPinned: Bool
    let completedSteps: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.chromeGuideTitle)
                .font(.callout.weight(.semibold))

            ForEach(Array(copy.chromeInstallSteps.enumerated()), id: \.offset) { index, instruction in
                HStack(alignment: .top, spacing: 10) {
                    guideBadge(index: index)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(instruction)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if index == 0 {
                            pathCopyStatus
                        }
                    }
                }
            }

            Text(copy.chromeReturnToMimi)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isVerified {
                Label(copy.chromeConnectionReady, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)

                Label(
                    isPinned ? copy.chromePinDetected : copy.chromePinInstruction,
                    systemImage: isPinned ? "pin.fill" : "pin"
                )
                .font(.caption.weight(isPinned ? .semibold : .regular))
                .foregroundStyle(isPinned ? Color.green : Color.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func guideBadge(index: Int) -> some View {
        let complete = isGuideStepComplete(index)
        Image(systemName: complete ? "checkmark.circle.fill" : "\(index + 1).circle.fill")
            .foregroundStyle(complete ? Color.green : Color.blue)
            .font(.body.weight(.semibold))
            .frame(width: 22)
    }

    private func isGuideStepComplete(_ index: Int) -> Bool {
        completedSteps.contains(index)
    }

    private var pathCopyStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                pathStatusText,
                systemImage: pathStatusIcon
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(pathStatusColor)
            if hasStartedSetup, !isPathCopied, !extensionFolderPath.isEmpty {
                Text(extensionFolderPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var pathStatusText: String {
        if !hasStartedSetup { return copy.chromePathWillCopy }
        return isPathCopied ? copy.chromePathCopied : copy.chromePathCopyFailed
    }

    private var pathStatusIcon: String {
        if !hasStartedSetup { return "doc.on.clipboard" }
        return isPathCopied ? "doc.on.clipboard.fill" : "exclamationmark.triangle.fill"
    }

    private var pathStatusColor: Color {
        if !hasStartedSetup { return .blue }
        return isPathCopied ? .green : .orange
    }
}

struct ChromeSetupPanel: View {
    let copy: SetupWizardCopy
    @ObservedObject var model: SetupViewModel

    var body: some View {
        let state = model.state(for: .chromeConnection)
        SetupPanel(step: 2, state: state, stateText: copy.title(for: state), title: copy.helperPanelTitle, systemImage: "puzzlepiece.extension.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy.chromeHelperExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: model.prepareChromeConnection) {
                    if model.isChromeSetupRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(copy.prepareChromeConnectionRunning)
                        }
                    } else {
                        Label(copy.prepareChromeConnection, systemImage: "bolt.horizontal.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isRunning)

                Text(copy.chromeManualConfirmation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ChromeInstallGuideView(
                    copy: copy,
                    extensionFolderPath: model.extensionFolderPath,
                    hasStartedSetup: model.hasStartedChromeSetup,
                    isPathCopied: model.isExtensionPathCopied,
                    isVerified: model.isChromeExtensionVerified,
                    isPinned: model.isChromePinnedConfirmed,
                    completedSteps: model.chromeGuideCompletedSteps
                )

                ChromeTroubleshootingView(copy: copy, model: model)
            }
        }
    }
}

private struct ChromeTroubleshootingView: View {
    let copy: SetupWizardCopy
    @ObservedObject var model: SetupViewModel

    var body: some View {
        DisclosureGroup(copy.chromeTroubleshootingTitle) {
            HStack(spacing: 10) {
                Button(action: model.openChromeExtension) {
                    Label(copy.openChromeExtension, systemImage: "square.on.square")
                }
                .buttonStyle(.bordered)
                Button(action: model.installHelper) {
                    Label(copy.installHelper, systemImage: "link")
                }
                .buttonStyle(.bordered)
                .disabled(model.isRunning)
                Button(action: model.startServer) {
                    Label(copy.startServer, systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(model.isRunning)
                Button(action: model.openStatus) {
                    Label(copy.openStatus, systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }
}

struct MimiMark: View {
    let iconURL: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Color(red: 0.02, green: 0.07, blue: 0.13))
                .shadow(color: Color(red: 0.18, green: 0.75, blue: 0.95).opacity(0.22), radius: size * 0.22, y: size * 0.08)

            if let iconURL, let image = NSImage(contentsOf: iconURL) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.10)
            } else {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.46, blue: 1.0), Color(red: 0.21, green: 0.79, blue: 0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("M")
                    .font(.system(size: size * 0.50, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}
