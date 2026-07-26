import AppKit
import Foundation
import MimiAppCore

@MainActor
final class SetupViewModel: ObservableObject {
    @Published var credentialInput = ""
    @Published var monthlyLimitEnabled = false
    @Published var safetyLimitInput = "30"
    @Published var safetySummary = "API利用の設定: 必要な場合だけ変更できます"
    @Published var safetyLimitMinutes = 30.0
    @Published var safetyUsedMinutes = 0.0
    @Published var safetyRemainingMinutes = 30.0
    @Published var isRunning = false
    @Published var rows: [SetupRow] = []
    @Published var message: SetupStatusMessage = .ready
    @Published var isChromeConnectionReady = false
    @Published var isChromeExtensionVerified = false
    @Published var isChromePinnedConfirmed = false
    @Published var isExtensionPathCopied = false
    @Published var isChromeExtensionsPageOpened = false
    @Published var hasStartedChromeSetup = false
    @Published var hasChromeSetupFailure = false
    @Published var isChromeSetupRunning = false
    @Published var isGoogleKeyConfigured = false
    @Published var hasStartedListening = false
    @Published var chromeGuideCompletedSteps: Set<Int> = []
    @Published private(set) var preferredProvider: MimiProvider = .gemini
    @Published private(set) var activeSessionCount = 0
    @Published private(set) var isProviderSaving = false

    let brandIconURL: URL?
    let keychainItemName = KeychainWriter.defaultService
    let keychainAccount = KeychainWriter.defaultAccount
    var extensionFolderPath: String { paths?.extensionDirectory.path ?? "" }

    private let paths: MimiPaths?
    private let keychain: KeychainWriter
    private let safetyLimitStore: LocalSafetyLimitStore?
    private let freshSetupPreview: Bool
    private let validationStore: SetupValidationStore
    private let storedGoogleKeyExists: () -> Bool
    private let existingGoogleKeyValidator: (() async throws -> CommandResult)?
    private let statusClient: ServerStatusClient
    private let setupCommandRunner: any SetupCommandRunning
    private let chromeURLLauncher: any ChromeURLLaunching
    private let clipboardWriter: any ClipboardWriting
    private let chromeExtensionsURL = URL(string: "chrome://extensions/")!
    private var serverStatus: ServerStatus?
    private let automaticRefreshIntervalNanoseconds: UInt64
    private let listeningCompletionNotBefore: Date?

    var canChangeProvider: Bool {
        !isRunning && !isProviderSaving && activeSessionCount == 0
    }

    init(
        paths: MimiPaths? = MimiPaths.discover(),
        launchOptions: SetupLaunchOptions = SetupLaunchOptions(),
        defaults: UserDefaults = .standard,
        startsAutomaticRefresh: Bool = true,
        storedGoogleKeyExists: (() -> Bool)? = nil,
        existingGoogleKeyValidator: (() async throws -> CommandResult)? = nil,
        statusClient: ServerStatusClient = ServerStatusClient(),
        setupCommandRunner: any SetupCommandRunning = CommandRunner(),
        chromeURLLauncher: (any ChromeURLLaunching)? = nil,
        clipboardWriter: (any ClipboardWriting)? = nil,
        automaticRefreshIntervalNanoseconds: UInt64 = 500_000_000,
        now: () -> Date = Date.init
    ) {
        let keychain = KeychainWriter()
        self.paths = paths
        self.keychain = keychain
        self.brandIconURL = Self.resolveBrandIconURL(paths: paths)
        self.safetyLimitStore = paths.map { LocalSafetyLimitStore(paths: $0) }
        self.freshSetupPreview = launchOptions.freshSetupPreview
        self.validationStore = SetupValidationStore(defaults: defaults)
        self.storedGoogleKeyExists = storedGoogleKeyExists ?? { keychain.hasPassword() }
        self.existingGoogleKeyValidator = existingGoogleKeyValidator
        self.statusClient = statusClient
        self.setupCommandRunner = setupCommandRunner
        self.chromeURLLauncher = chromeURLLauncher ?? SystemChromeURLLauncher()
        self.clipboardWriter = clipboardWriter ?? SystemClipboardWriter()
        self.automaticRefreshIntervalNanoseconds = automaticRefreshIntervalNanoseconds
        self.listeningCompletionNotBefore = launchOptions.freshSetupPreview ? now() : nil
        self.hasStartedListening = launchOptions.freshSetupPreview
            ? false
            : validationStore.isListeningStarted()
        self.isGoogleKeyConfigured = launchOptions.chromeSetupPreview
            || (!launchOptions.freshSetupPreview
                && validationStore.isGoogleKeyValidated(hasKey: self.storedGoogleKeyExists()))
        if launchOptions.freshSetupPreview {
            self.message = .needsAttention
        }
        refreshSafetyLimitSummary()
        refreshRows()
        if startsAutomaticRefresh && !launchOptions.chromeSetupPreview {
            startAutomaticRefresh()
            Task { await validateExistingGoogleKeyIfNeeded() }
        }
    }

    private static func resolveBrandIconURL(paths: MimiPaths?) -> URL? {
        let fileManager = FileManager.default
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("MimiSetupChromeIcon.png"),
           fileManager.fileExists(atPath: bundled.path) {
            return bundled
        }
        guard let paths else { return nil }
        let repositoryIcon = paths.extensionDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("MimiApp/Resources/MimiSetupChromeIcon.png")
        return fileManager.fileExists(atPath: repositoryIcon.path)
            ? repositoryIcon
            : nil
    }

    func openChromeExtension() {
        hasStartedChromeSetup = true
        refreshRows()
        message = .chromeSetupOpening
        Task {
            let result = await openChromeExtensionSetupPage()
            message = statusMessage(for: result)
            hasChromeSetupFailure = !result.chromeOpened
            refreshRows()
        }
    }

    @discardableResult
    private func openChromeExtensionSetupPage() async -> ChromeSetupOpenResult {
        guard let paths else {
            message = .repoMissing
            return ChromeSetupOpenResult(pathCopied: false, chromeOpened: false, errorDescription: "Mimi folder was not found.")
        }
        isExtensionPathCopied = clipboardWriter.writeString(paths.extensionDirectory.path)
        let result = await chromeURLLauncher.openChromeURL(chromeExtensionsURL)
        isChromeExtensionsPageOpened = result.opened
        if isExtensionPathCopied && result.opened { chromeGuideCompletedSteps.insert(0) }
        return ChromeSetupOpenResult(
            pathCopied: isExtensionPathCopied,
            chromeOpened: result.opened,
            errorDescription: result.errorDescription
        )
    }

    func openAIStudioFirstRun() {
        openInChrome(URL(string: OnboardingCopy.aiStudioHomeURL)!)
    }

    func openAIStudioAPIKeys() {
        openInChrome(URL(string: OnboardingCopy.aiStudioAPIKeysURL)!)
    }

    func openStatus() {
        open(URL(string: "http://127.0.0.1:8787/status")!)
    }

    func openKeychainAccess() {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            workspace.open(url)
            return
        }
        workspace.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Keychain Access.app"))
    }

    func copyKeychainItemName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(keychainItemName, forType: .string)
    }

    func prepareChromeConnection() {
        hasStartedChromeSetup = true
        hasChromeSetupFailure = false
        isChromeExtensionVerified = false
        isChromePinnedConfirmed = false
        isChromeConnectionReady = false
        isExtensionPathCopied = false
        isChromeExtensionsPageOpened = false
        chromeGuideCompletedSteps = []
        isRunning = true
        isChromeSetupRunning = true
        message = .chromeSetupOpening
        refreshRows()
        Task {
            defer {
                self.isRunning = false
                self.isChromeSetupRunning = false
                self.refreshRows()
            }
            do {
                let openResult = await openChromeExtensionSetupPage()
                if !openResult.chromeOpened {
                    hasChromeSetupFailure = true
                    message = statusMessage(for: openResult)
                    return
                }
                if !openResult.pathCopied {
                    message = .extensionPathCopyFailed
                }
                try await prepareChromeConnectionAndWaitForExtension()
            } catch SetupActionError.chromeExtensionNotVerified {
                hasChromeSetupFailure = true
                message = .chromeSetupFailed
            } catch {
                hasChromeSetupFailure = true
                message = .custom(error.localizedDescription)
            }
        }
    }

    private func prepareChromeConnectionAndWaitForExtension() async throws {
        guard let runner = setupRunner() else { throw SetupError.repoMissing }
        let result = try await runner.prepareChromeConnection()
        guard result.succeeded else {
            hasChromeSetupFailure = true
            message = .custom(result.output)
            return
        }

        _ = try await statusClient.waitUntilServerPrepared()
        message = .chromeInstallPending

        do {
            let status = try await statusClient.waitUntilReady(
                maxAttempts: 240,
                retryDelayNanoseconds: 500_000_000,
                onStatus: { status in
                    if status.extensionConnection?.verified == true {
                        self.apply(status: status)
                    }
                }
            )
            apply(status: status)
        } catch {
            throw SetupActionError.chromeExtensionNotVerified
        }
    }

    func saveLimitAndRestartServer() {
        run(.saveLimitSuccess) {
            guard let store = self.safetyLimitStore else { throw SetupError.repoMissing }
            let minutes = try self.parseSafetyLimitInput()
            try store.saveMonthlyLimit(enabled: self.monthlyLimitEnabled, minutes: minutes)
            self.refreshSafetyLimitSummary()
            guard let runner = self.setupRunner() else { throw SetupError.repoMissing }
            let result = try await runner.restartLocalServer()
            await self.refreshStatus()
            return result
        }
    }

    func resetUsageCounter() {
        run(.resetUsageSuccess) {
            guard let store = self.safetyLimitStore else { throw SetupError.repoMissing }
            _ = try store.resetUsageCounter()
            self.refreshSafetyLimitSummary()
            return CommandResult(command: "local_usage_reset", exitCode: 0, output: "")
        }
    }

    func adjustSafetyLimit(by delta: Double) {
        let current = (try? parseSafetyLimitInput()) ?? safetyLimitMinutes
        let updated = max(1, current + delta)
        safetyLimitInput = formatMinutes(updated)
    }

    func saveKeyAndTest() {
        run(.saveKeySuccess) {
            try self.keychain.save(self.credentialInput)
            self.validationStore.markGoogleKeyValidated(false)
            self.isGoogleKeyConfigured = false
            guard let runner = self.setupRunner() else { throw SetupError.repoMissing }
            let result = try await runner.runConnectionTest()
            guard result.succeeded else { return result }
            self.credentialInput = ""
            self.validationStore.markGoogleKeyValidated(true)
            self.isGoogleKeyConfigured = true
            return result
        }
    }

    func installHelper() {
        run(.helperSuccess) {
            guard let runner = self.setupRunner() else { throw SetupError.repoMissing }
            let install = try await runner.installNativeHost()
            guard install.succeeded else { return install }
            return try await runner.checkNativeHost()
        }
    }

    func startServer() {
        run(.serverSuccess) {
            guard let runner = self.setupRunner() else { throw SetupError.repoMissing }
            let result = try await runner.startLocalServer()
            await self.refreshStatus()
            return result
        }
    }

    func refreshStatus() async {
        do {
            let status = try await statusClient.fetchStatus()
            apply(status: status)
        } catch {
            serverStatus = nil
            isChromeExtensionVerified = false
            updateChromeConnectionReadiness()
            refreshRows()
        }
    }

    /// Saves the provider through the local server and adopts its canonical response.
    /// A running translation session must be stopped before changing provider.
    func selectProvider(_ provider: MimiProvider) {
        guard provider != preferredProvider, canChangeProvider else { return }
        let previousProvider = preferredProvider
        isProviderSaving = true
        Task {
            defer {
                self.isProviderSaving = false
            }
            do {
                preferredProvider = try await statusClient.setPreferredProvider(provider)
            } catch {
                preferredProvider = previousProvider
                message = .custom(error.localizedDescription)
            }
        }
    }

    func validateExistingGoogleKeyIfNeeded() async {
        guard !freshSetupPreview,
              !isGoogleKeyConfigured,
              storedGoogleKeyExists()
        else { return }

        isRunning = true
        defer {
            isRunning = false
            refreshRows()
        }
        do {
            let result: CommandResult
            if let existingGoogleKeyValidator {
                result = try await existingGoogleKeyValidator()
            } else {
                guard let runner = setupRunner() else { return }
                result = try await runner.runConnectionTest()
            }
            guard result.succeeded else { return }
            validationStore.markGoogleKeyValidated(true)
            isGoogleKeyConfigured = true
            message = isChromeConnectionReady ? .readyForChrome : .saveKeySuccess
        } catch {
            // Keep Step 1 open so the user can replace an invalid or unavailable key.
        }
    }

    private func run(_ successMessage: SetupStatusMessage, operation: @escaping () async throws -> CommandResult) {
        isRunning = true
        message = .running
        Task {
            do {
                let result = try await operation()
                message = result.succeeded ? successMessage : .custom(result.output)
            } catch {
                message = .custom(error.localizedDescription)
            }
            isRunning = false
            refreshRows()
        }
    }

    func apply(status: ServerStatus) {
        serverStatus = status
        activeSessionCount = max(0, status.activeSessions)
        if !isProviderSaving, let preferredProvider = status.preferredProvider {
            self.preferredProvider = preferredProvider
        }
        isChromeExtensionVerified = status.extensionConnection?.verified == true
        isChromePinnedConfirmed = status.extensionConnection?.isOnToolbar == true
        updateChromeGuideProgress(status.extensionConnection)
        if isCurrentListeningCompletion(status.setupProgress) {
            hasStartedListening = true
            validationStore.markListeningStarted(true)
        }
        if status.isReadyForChrome {
            hasChromeSetupFailure = false
        }
        updateChromeConnectionReadiness()
        refreshSafetyLimitSummary(billing: status.billing)
        refreshRows()
    }

    private func updateChromeConnectionReadiness() {
        isChromeConnectionReady = serverStatus?.isReadyForChrome == true
            && (!freshSetupPreview || hasStartedChromeSetup)
        if isChromeConnectionReady {
            message = .readyForChrome
        } else if serverStatus?.isServerPreparedForChrome == true && isChromeExtensionVerified {
            message = .chromePinRequired
        } else {
            message = .needsAttention
        }
    }

    private func startAutomaticRefresh() {
        Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.refreshStatus()
                try? await Task.sleep(nanoseconds: self.automaticRefreshIntervalNanoseconds)
            }
        }
    }

    private func updateChromeGuideProgress(_ connection: ServerStatus.ExtensionConnectionStatus?) {
        var completed: Set<Int> = []
        guard hasStartedChromeSetup else {
            chromeGuideCompletedSteps = completed
            return
        }
        if hasStartedChromeSetup && isExtensionPathCopied && isChromeExtensionsPageOpened { completed.insert(0) }
        if connection?.installedAt != nil { completed.insert(1) }
        if connection?.isOnToolbar == true, connection?.toolbarChangedAt != nil { completed.insert(2) }
        if connection?.popupOpenedAt != nil, connection?.isOnToolbar == true { completed.insert(3) }
        chromeGuideCompletedSteps = completed
    }

    private func isCurrentListeningCompletion(_ progress: ServerStatus.SetupProgressStatus?) -> Bool {
        guard progress?.listeningStarted == true else { return false }
        guard let listeningCompletionNotBefore else { return true }
        guard let timestamp = progress?.listeningStartedAt,
              let completedAt = parseServerTimestamp(timestamp)
        else { return false }
        return completedAt >= listeningCompletionNotBefore
    }

    private func parseServerTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func refreshSafetyLimitSummary(billing: ServerStatus.BillingStatus? = nil) {
        if let billing {
            monthlyLimitEnabled = billing.monthlyLimitEnabled == true
            safetyLimitInput = formatMinutes(billing.limitMinutes)
            safetyLimitMinutes = billing.limitMinutes
            safetyUsedMinutes = billing.usedMinutes
            safetyRemainingMinutes = billing.remainingMinutes
            safetySummary = monthlyLimitEnabled
                ? "月間保護は有効です。今月 \(formatMinutes(billing.usedMinutes)) / \(formatMinutes(billing.limitMinutes)) 分 使用。残り \(formatMinutes(billing.remainingMinutes)) 分。"
                : "無料キー向けの月間保護はオフです。使い忘れ防止の自動停止はChrome拡張で30分が初期値です。"
            return
        }

        guard let store = safetyLimitStore else {
            safetyLimitInput = "30"
            safetyLimitMinutes = 30
            safetyUsedMinutes = 0
            safetyRemainingMinutes = 30
            safetySummary = "Mimiのフォルダが見つかりません"
            return
        }
        let summary = store.readSummary()
        monthlyLimitEnabled = summary.monthlyLimitEnabled
        safetyLimitInput = formatMinutes(summary.limitMinutes)
        safetyLimitMinutes = summary.limitMinutes
        safetyUsedMinutes = summary.usedMinutes
        safetyRemainingMinutes = summary.remainingMinutes
        safetySummary = monthlyLimitEnabled
            ? "月間保護は有効です。今月 \(formatMinutes(summary.usedMinutes)) / \(formatMinutes(summary.limitMinutes)) 分 使用。残り \(formatMinutes(summary.remainingMinutes)) 分。"
            : "無料キー向けの月間保護はオフです。使い忘れ防止の自動停止はChrome拡張で30分が初期値です。"
    }

    private func refreshRows() {
        let keyReady = isGoogleKeyConfigured
        let chromeReady = isChromeConnectionReady
        let listeningState: SetupState = if hasStartedListening {
            .done
        } else if chromeReady {
            .ready
        } else {
            .notStarted
        }
        let chromeState: SetupState = if chromeReady {
            .done
        } else if isChromeSetupRunning && hasStartedChromeSetup {
            .running
        } else if hasChromeSetupFailure {
            .needsAttention
        } else if isChromeExtensionVerified {
            .needsAttention
        } else {
            .notStarted
        }
        rows = [
            SetupRow(step: 1, kind: .googleKey, state: keyReady ? .done : .needsAttention),
            SetupRow(step: 2, kind: .chromeConnection, state: chromeState),
            SetupRow(step: 3, kind: .startListening, state: listeningState)
        ]
    }

    func state(for kind: SetupRowKind) -> SetupState {
        rows.first { $0.kind == kind }?.state ?? .notStarted
    }

    private func setupRunner() -> SetupRunner? {
        paths.map {
            var environment: [String: String] = [:]
            if let safetyLimitStore {
                environment["JP_DUB_MONTHLY_LIMIT_ENABLED"] = safetyLimitStore.readMonthlyLimitEnabled() ? "true" : "false"
                environment["JP_DUB_MONTHLY_LIMIT_MINUTES"] = formatMinutes(safetyLimitStore.readLimitMinutes())
            }
            return SetupRunner(paths: $0, runner: setupCommandRunner, environment: environment)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func openInChrome(_ url: URL) {
        Task {
            let result = await chromeURLLauncher.openChromeURL(url)
            if !result.opened {
                chromeURLLauncher.openDefaultURL(url)
            }
        }
    }

    private func statusMessage(for result: ChromeSetupOpenResult) -> SetupStatusMessage {
        guard result.chromeOpened else {
            return .chromeSetupOpenFailed(result.errorDescription)
        }
        return result.pathCopied ? .extensionPathCopied : .extensionPathCopyFailed
    }

    private func parseSafetyLimitInput() throws -> Double {
        let normalized = safetyLimitInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Double(normalized), minutes > 0 else {
            throw LocalSafetyLimitError.invalidLimit
        }
        return minutes
    }

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes.rounded() == minutes {
            return String(Int(minutes))
        }
        return String(format: "%.1f", minutes)
    }
}
