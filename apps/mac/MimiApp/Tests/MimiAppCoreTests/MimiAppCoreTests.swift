import CoreGraphics
import Foundation
import Security
import Testing
@testable import MimiAppCore

@Test func serverStatusDecodesSafeReadinessFields() throws {
    let data = """
    {
      "ok": true,
      "service": "jp-dub-local-server",
      "mode": "real",
      "activeSessions": 0,
      "realModeReady": true,
      "allowedExtensionOriginConfigured": true,
      "allowedExtensionId": "oknekoaclmnljnlpmffphpiflcdeibgg",
      "extensionConnection": {
        "verified": true,
        "lastSeenAt": "2026-07-10T03:00:00.000Z",
        "isOnToolbar": true,
        "installedAt": "2026-07-10T02:58:00.000Z",
        "toolbarChangedAt": "2026-07-10T02:59:00.000Z",
        "popupOpenedAt": "2026-07-10T03:00:00.000Z"
      },
      "setupProgress": {
        "listeningStarted": true,
        "listeningStartedAt": "2026-07-13T01:00:00.000Z"
      },
      "diagnostics": { "enabled": false },
      "billing": {
        "monthlyLimitEnabled": false,
        "limitSeconds": 1800,
        "usedSeconds": 300,
        "remainingSeconds": null
      }
    }
    """.data(using: .utf8)!

    let status = try JSONDecoder().decode(ServerStatus.self, from: data)

    #expect(status.isMimiServer)
    #expect(status.isServerPreparedForChrome)
    #expect(status.isReadyForChrome)
    #expect(status.extensionConnection?.verified == true)
    #expect(status.extensionConnection?.isOnToolbar == true)
    #expect(status.setupProgress?.listeningStarted == true)
    #expect(status.setupProgress?.listeningStartedAt == "2026-07-13T01:00:00.000Z")
    #expect(status.diagnostics?.enabled == false)
    #expect(status.billing?.monthlyLimitEnabled == false)
    #expect(status.billing?.limitMinutes == 30)
    #expect(status.billing?.remainingMinutes == 0)
}

@Test func serverStatusProviderIsTypedAndOptionalForOlderServers() throws {
    let withProvider = """
    {
      "ok": true,
      "service": "jp-dub-local-server",
      "mode": "real",
      "activeSessions": 0,
      "realModeReady": false,
      "allowedExtensionOriginConfigured": false,
      "allowedExtensionId": "",
      "preferredProvider": "openai"
    }
    """.data(using: .utf8)!
    let withoutProvider = """
    {
      "ok": true,
      "service": "jp-dub-local-server",
      "mode": "real",
      "activeSessions": 0,
      "realModeReady": false,
      "allowedExtensionOriginConfigured": false,
      "allowedExtensionId": ""
    }
    """.data(using: .utf8)!

    #expect(try JSONDecoder().decode(ServerStatus.self, from: withProvider).preferredProvider == .openai)
    #expect(try JSONDecoder().decode(ServerStatus.self, from: withoutProvider).preferredProvider == nil)
}

@Test func serverStatusNormalizesStaleXAIProviderToGemini() throws {
    let data = """
    {
      "ok": true,
      "service": "jp-dub-local-server",
      "mode": "real",
      "activeSessions": 0,
      "realModeReady": false,
      "allowedExtensionOriginConfigured": false,
      "allowedExtensionId": "",
      "preferredProvider": "xai"
    }
    """.data(using: .utf8)!

    let status = try JSONDecoder().decode(ServerStatus.self, from: data)

    #expect(status.preferredProvider == .gemini)
    #expect(MimiProvider(rawValue: "xai") == nil)
}

@Test func serverStatusIgnoresUnknownFutureProvider() throws {
    let data = """
    {
      "ok": true,
      "service": "jp-dub-local-server",
      "mode": "real",
      "activeSessions": 0,
      "realModeReady": false,
      "allowedExtensionOriginConfigured": false,
      "allowedExtensionId": "",
      "preferredProvider": "future-provider"
    }
    """.data(using: .utf8)!

    let status = try JSONDecoder().decode(ServerStatus.self, from: data)

    #expect(status.isMimiServer)
    #expect(status.preferredProvider == nil)
    #expect(MimiProvider(rawValue: "future-provider") == nil)
}

@Test func serverStatusClientInjectsProviderWriteAndUsesCanonicalResponse() async throws {
    var writes: [MimiProvider] = []
    let client = ServerStatusClient(
        fetchStatus: { throw ServerStatusError.notReady },
        writeProvider: { provider in
            writes.append(provider)
            return ProviderSettingsResponse(ok: true, preferredProvider: .openai)
        }
    )

    let selected = try await client.setPreferredProvider(.gemini)

    #expect(writes == [.gemini])
    #expect(selected == .openai)
}

@Test func providerSettingsResponseNormalizesStaleXAIProviderToGemini() throws {
    let data = """
    {
      "ok": true,
      "preferredProvider": "xai"
    }
    """.data(using: .utf8)!

    let response = try JSONDecoder().decode(ProviderSettingsResponse.self, from: data)

    #expect(response.preferredProvider == .gemini)
}

@Test func setupLaunchOptionsOnlyEnableFreshPreviewWhenExplicit() {
    #expect(!SetupLaunchOptions(arguments: ["Mimi"]).freshSetupPreview)
    #expect(SetupLaunchOptions(arguments: ["Mimi", "--fresh-setup-preview"]).freshSetupPreview)
    #expect(!SetupLaunchOptions(arguments: ["Mimi", "--fresh"]).freshSetupPreview)
    #expect(!SetupLaunchOptions(arguments: ["Mimi"]).chromeSetupPreview)
    #expect(SetupLaunchOptions(arguments: ["Mimi", "--chrome-setup-preview"]).chromeSetupPreview)
}

@Test func googleKeySetupRequiresAStoredSuccessfulConnectionTest() {
    let suiteName = "MimiAppCoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SetupValidationStore(defaults: defaults)

    #expect(!store.isGoogleKeyValidated(hasKey: true))
    store.markGoogleKeyValidated(true)
    #expect(store.isGoogleKeyValidated(hasKey: true))
    #expect(!store.isGoogleKeyValidated(hasKey: false))
    store.markGoogleKeyValidated(false)
    #expect(!store.isGoogleKeyValidated(hasKey: true))
}

@Test func fixedExtensionPopupURLTargetsTheBundledMimiExtension() {
    #expect(
        ExtensionOriginResolver.fixedPopupURL
            == "chrome-extension://oknekoaclmnljnlpmffphpiflcdeibgg/src/popup.html"
    )
}

@Test func serverStatusWaitsUntilChromeIsReady() async throws {
    let sequence = StatusSequence([
        try makeServerStatus(serverReady: true, extensionVerified: false),
        try makeServerStatus(serverReady: true, extensionVerified: true)
    ])
    let client = ServerStatusClient(fetchStatus: { try await sequence.next() })

    let status = try await client.waitUntilReady(maxAttempts: 3, retryDelayNanoseconds: 0)

    #expect(status.isReadyForChrome)
    #expect(await sequence.fetchCount() == 2)
}

@Test func serverStatusWaitPublishesVerifiedButUnpinnedStatus() async throws {
    let sequence = StatusSequence([
        try makeServerStatus(serverReady: true, extensionVerified: false),
        try makeServerStatus(serverReady: true, extensionVerified: true, toolbarPinned: false),
        try makeServerStatus(serverReady: true, extensionVerified: true, toolbarPinned: true)
    ])
    let client = ServerStatusClient(fetchStatus: { try await sequence.next() })
    var observed: [ServerStatus] = []

    let status = try await client.waitUntilReady(maxAttempts: 3, retryDelayNanoseconds: 0) { status in
        observed.append(status)
    }

    #expect(status.isReadyForChrome)
    #expect(observed.count == 3)
    #expect(observed[1].extensionConnection?.verified == true)
    #expect(observed[1].extensionConnection?.isOnToolbar == false)
}

@Test func serverPreparationDoesNotClaimChromeExtensionIsConnected() async throws {
    let status = try makeServerStatus(serverReady: true, extensionVerified: false)

    #expect(status.isServerPreparedForChrome)
    #expect(!status.isReadyForChrome)
}

@Test func serverStatusRequiresAutomaticToolbarPinDetection() throws {
    let status = try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: false
    )

    #expect(status.extensionConnection?.verified == true)
    #expect(status.extensionConnection?.isOnToolbar == false)
    #expect(!status.isReadyForChrome)
}

@Test func serverStatusCanWaitForServerBeforeExtensionInstallation() async throws {
    let sequence = StatusSequence([
        try makeServerStatus(serverReady: false, extensionVerified: false),
        try makeServerStatus(serverReady: true, extensionVerified: false)
    ])
    let client = ServerStatusClient(fetchStatus: { try await sequence.next() })

    let status = try await client.waitUntilServerPrepared(maxAttempts: 3, retryDelayNanoseconds: 0)

    #expect(status.isServerPreparedForChrome)
    #expect(!status.isReadyForChrome)
    #expect(await sequence.fetchCount() == 2)
}

@Test func setupRunnerPreparesChromeConnectionInOrder() async throws {
    let commandRunner = FakeSetupCommandRunner()
    let runner = SetupRunner(paths: makeSetupPaths(), runner: commandRunner)

    let result = try await runner.prepareChromeConnection()

    #expect(result.succeeded)
    #expect(commandRunner.scripts == [
        "scripts/install.js",
        "scripts/doctor.js",
        "scripts/stop.js",
        "scripts/start-detached.js"
    ])
    #expect(commandRunner.arguments.first == [
        "--extension-origin=chrome-extension://oknekoaclmnljnlpmffphpiflcdeibgg"
    ])
    #expect(commandRunner.environments.last?["JP_DUB_RESTART_EXISTING"] == "true")
}

@Test func setupRunnerStopsAutomaticPreparationAfterFailure() async throws {
    let commandRunner = FakeSetupCommandRunner(failingScript: "scripts/doctor.js")
    let runner = SetupRunner(paths: makeSetupPaths(), runner: commandRunner)

    let result = try await runner.prepareChromeConnection()

    #expect(!result.succeeded)
    #expect(commandRunner.scripts == ["scripts/install.js", "scripts/doctor.js"])
}

@Test func setupRunnerKeepsExplicitExtensionOriginOverride() async throws {
    let commandRunner = FakeSetupCommandRunner()
    let customOrigin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let runner = SetupRunner(
        paths: makeSetupPaths(),
        runner: commandRunner,
        environment: ["MIMI_EXTENSION_ORIGIN": customOrigin]
    )

    _ = try await runner.installNativeHost()

    #expect(commandRunner.arguments.first == ["--extension-origin=\(customOrigin)"])
    #expect(commandRunner.environments.first?["MIMI_EXTENSION_ORIGIN"] == customOrigin)
}

@Test func redactionRemovesKeyLikeValues() {
    let googleKeyLikeValue = "AI" + "za" + String(repeating: "x", count: 24)
    let text = "GEMINI_" + "API_KEY=\(googleKeyLikeValue) key=secret-value token=abc"
    let redacted = redactSecrets(text)

    #expect(!redacted.contains(googleKeyLikeValue))
    #expect(!redacted.contains("secret-value"))
    #expect(!redacted.contains("token=abc"))
}

@Test func keychainWriterUpdatesExistingItemOnDuplicate() throws {
    let fake = FakeKeychain(addStatuses: [errSecDuplicateItem], updateStatuses: [errSecSuccess])
    let writer = KeychainWriter(service: "Mimi Test Service", account: "default", keychain: fake)

    try writer.save("  mimi-test-key  ")

    #expect(fake.addedPasswords == ["mimi-test-key"])
    #expect(fake.updatedPasswords == ["mimi-test-key"])
    #expect(fake.updateQueries.count == 1)
    #expect(fake.updateQueries[0][kSecAttrService as String] as? String == "Mimi Test Service")
    #expect(fake.updateQueries[0][kSecAttrAccount as String] as? String == "default")
}

@Test func keychainWriterRejectsBlankKeyBeforeKeychainAccess() {
    let fake = FakeKeychain()
    let writer = KeychainWriter(keychain: fake)

    #expect(throws: KeychainError.emptyPassword) {
        try writer.save(" \n\t ")
    }
    #expect(fake.addedPasswords.isEmpty)
    #expect(fake.updatedPasswords.isEmpty)
}

@Test func keychainDuplicateErrorMessageIsActionableJapanese() {
    let message = KeychainError.unexpectedStatus(errSecDuplicateItem).localizedDescription

    #expect(message.contains("Keychain"))
    #expect(message.contains("再試行"))
    #expect(!message.contains("-25299"))
    #expect(!message.contains("Keychain operation failed"))
}

@Test func nodeRuntimePrefersBundledNodeWhenPresent() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mimi-node-runtime-test-\(UUID().uuidString)")
    let node = root
        .appendingPathComponent("node")
        .appendingPathComponent("bin")
        .appendingPathComponent("node")
    try FileManager.default.createDirectory(at: node.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: node.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
    defer { try? FileManager.default.removeItem(at: root) }

    let invocation = NodeRuntime(resourceURL: root, environment: [:])
        .invocation(forScript: "scripts/doctor.js")

    #expect(invocation.executable == node)
    #expect(invocation.arguments == ["scripts/doctor.js"])
}

@Test func safetyLimitStoreUpdatesOnlyLimitLine() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalSafetyLimitStore(root: root)
    try FileManager.default.createDirectory(at: store.envFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    JP_DUB_TARGET_LANGUAGE=ja
    JP_DUB_MONTHLY_LIMIT_MINUTES=30
    OTHER_VALUE=kept
    """.write(to: store.envFileURL, atomically: true, encoding: .utf8)

    try store.saveLimitMinutes(180)

    let updated = try String(contentsOf: store.envFileURL, encoding: .utf8)
    #expect(updated.contains("JP_DUB_TARGET_LANGUAGE=ja"))
    #expect(updated.contains("JP_DUB_MONTHLY_LIMIT_ENABLED=true"))
    #expect(updated.contains("JP_DUB_MONTHLY_LIMIT_MINUTES=180"))
    #expect(updated.contains("OTHER_VALUE=kept"))
    #expect(store.readMonthlyLimitEnabled())
    #expect(store.readLimitMinutes() == 180)
}

@Test func safetyLimitStoreDefaultsMonthlyProtectionOff() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalSafetyLimitStore(root: root)

    let summary = store.readSummary(now: Date(timeIntervalSince1970: 1_782_777_600))

    #expect(!summary.monthlyLimitEnabled)
    #expect(summary.limitMinutes == 30)
}

@Test func safetyLimitStorePreservesLegacyPaidMonthlyProtection() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalSafetyLimitStore(root: root)
    try FileManager.default.createDirectory(at: store.envFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "JP_DUB_MONTHLY_LIMIT_MINUTES=45\n".write(to: store.envFileURL, atomically: true, encoding: .utf8)

    #expect(store.readMonthlyLimitEnabled())
}

@Test func safetyLimitStoreKeepsLegacyFreeTierMonthlyProtectionOff() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalSafetyLimitStore(root: root)
    try FileManager.default.createDirectory(at: store.envFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    JP_DUB_FREE_TIER_MODE=true
    JP_DUB_MONTHLY_LIMIT_MINUTES=45
    """.write(to: store.envFileURL, atomically: true, encoding: .utf8)

    #expect(!store.readMonthlyLimitEnabled())
}

@Test func safetyLimitStoreResetsUsageCounterWithBackup() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalSafetyLimitStore(root: root)
    try FileManager.default.createDirectory(at: store.usageFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"{"month":"2026-06","usedSeconds":600}"#
        .write(to: store.usageFileURL, atomically: true, encoding: .utf8)

    let backup = try store.resetUsageCounter(now: Date(timeIntervalSince1970: 1_782_777_600))

    #expect(!FileManager.default.fileExists(atPath: store.usageFileURL.path))
    #expect(backup != nil)
    #expect(FileManager.default.fileExists(atPath: backup!.path))
}

@Test func safetyLimitSummaryUsesConfiguredLimitAndUsage() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalSafetyLimitStore(root: root)
    try FileManager.default.createDirectory(at: store.envFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: store.usageFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    JP_DUB_MONTHLY_LIMIT_ENABLED=true
    JP_DUB_MONTHLY_LIMIT_MINUTES=60
    """.write(to: store.envFileURL, atomically: true, encoding: .utf8)
    try #"{"month":"2026-06","usedSeconds":900}"#
        .write(to: store.usageFileURL, atomically: true, encoding: .utf8)

    let summary = store.readSummary(now: Date(timeIntervalSince1970: 1_782_777_600))

    #expect(summary.usageExists)
    #expect(summary.monthlyLimitEnabled)
    #expect(summary.limitMinutes == 60)
    #expect(summary.usedMinutes == 15)
    #expect(summary.remainingMinutes == 45)
}

@Test func mimiPathsCanDiscoverBundledResourceLayout() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Contents/Resources")
    let support = root.appendingPathComponent("ApplicationSupport")
    try createFile(resources.appendingPathComponent("local-server/package.json"), contents: "{}")
    try createFile(resources.appendingPathComponent("native-host/package.json"), contents: "{}")
    try createFile(resources.appendingPathComponent("extension/manifest.json"), contents: "{}")

    let paths = MimiPaths.discover(
        startingAt: root.appendingPathComponent("elsewhere"),
        resourceURL: resources,
        applicationSupportURL: support
    )

    #expect(paths?.localServerDirectory == resources.appendingPathComponent("local-server"))
    #expect(paths?.nativeHostDirectory == resources.appendingPathComponent("native-host"))
    #expect(paths?.extensionDirectory == resources.appendingPathComponent("extension"))
    #expect(paths?.envFileURL == support.appendingPathComponent("local-server/.env"))
    #expect(paths?.usageFileURL == support.appendingPathComponent("tmp/jp-dub-usage.json"))
    #expect(paths?.runtimeEnvironment["JP_DUB_ENV_FILE"] == support.appendingPathComponent("local-server/.env").path)
    #expect(paths?.runtimeEnvironment["JP_DUB_SETUP_PROGRESS_FILE"] == support.appendingPathComponent("tmp/mimi-setup-progress.json").path)
    #expect(paths?.runtimeEnvironment["MIMI_EXTENSION_ORIGIN"] == ExtensionOriginResolver().fixedOrigin())
}

@Test func onboardingCopyExplainsApiKeyPathWithoutExampleSecrets() {
    let copy = [
        OnboardingCopy.setupSummary,
        OnboardingCopy.apiKeyExplanation,
        OnboardingCopy.accountGuidance,
        OnboardingCopy.paidPathGuidance,
        OnboardingCopy.guidedKeySteps,
        OnboardingCopy.replaceKeyGuidance,
        OnboardingCopy.trustExplanation,
        OnboardingCopy.safetyExplanation,
        OnboardingCopy.chromeHelperExplanation,
        OnboardingCopy.prepareChromeConnection,
        OnboardingCopy.prepareChromeConnectionRunning,
        OnboardingCopy.chromeManualConfirmation,
        OnboardingCopy.chromeConnectionReady,
        OnboardingCopy.chromeTroubleshootingTitle,
        OnboardingCopy.keychainHelpTitle
    ].joined(separator: "\n")

    #expect(OnboardingCopy.aiStudioHomeURL == "https://aistudio.google.com/")
    #expect(OnboardingCopy.aiStudioAPIKeysURL == "https://aistudio.google.com/api-keys")
    #expect(OnboardingCopy.apiKeyTitle == "Googleの翻訳準備")
    #expect(OnboardingCopy.setupSummary.contains("番号の順"))
    #expect(OnboardingCopy.apiKeyExplanation.hasPrefix("初めてGoogle AI Studioを使う人は"))
    #expect(!OnboardingCopy.apiKeyExplanation.prefix(30).contains("API"))
    #expect(copy.contains("無料で使えるGemini APIキー"))
    #expect(copy.contains("Google AI Studio"))
    #expect(copy.contains("Googleアカウント"))
    #expect(copy.contains("必須の同意チェック"))
    #expect(copy.contains("続行"))
    #expect(copy.contains("APIキーのページ"))
    #expect(copy.contains("最初から表示されているGemini APIキー"))
    #expect(copy.contains("コピーボタン"))
    #expect(copy.contains("この欄に貼り付け"))
    #expect(copy.contains("無料のGemini APIキー"))
    #expect(copy.contains("月の利用時間を気にせず"))
    #expect(copy.contains("課金が有効なAPIキー"))
    #expect(copy.contains("任意で時間の目安"))
    #expect(copy.contains("Google Cloudの有料APIを使う方法"))
    #expect(copy.contains("有料課金を自動で始めることはありません"))
    #expect(copy.contains("差し替える場合"))
    #expect(copy.contains("macOS Keychain"))
    #expect(copy.contains("Chrome拡張"))
    #expect(copy.contains("chat"))
    #expect(copy.contains(".env"))
    #expect(OnboardingCopy.openAIStudioFirstRun.contains("初めての人"))
    #expect(OnboardingCopy.openAIStudioAPIKeys.contains("完了済みの人"))
    #expect(OnboardingCopy.saveAndTest.contains("差し替え"))
    #expect(!copy.contains("AI" + "za"))
    #expect(!copy.contains("GEMINI_" + "API_KEY="))
    #expect(!copy.contains("このMacの安全上限"))
    #expect(OnboardingCopy.finalStepThree.contains("聞く言語を選び"))
    #expect(!OnboardingCopy.finalStepThree.contains("聞く言語: 日本語"))
    #expect(OnboardingCopy.finalStepThree.contains("開始"))
    #expect(OnboardingCopy.safetyExplanation.contains("無料のGemini APIキー"))
    #expect(OnboardingCopy.safetyExplanation.contains("月の利用時間を気にせず"))
    #expect(OnboardingCopy.safetyExplanation.contains("使い忘れ防止"))
    #expect(OnboardingCopy.safetyExplanation.contains("初期値は30分"))
    #expect(OnboardingCopy.optionalSettingsLabel == "任意設定")
    #expect(OnboardingCopy.googleKeyReady.contains("Keychainに保存済み"))
    #expect(OnboardingCopy.changeGoogleKey.contains("差し替える"))
    #expect(OnboardingCopy.keychainHelpTitle.contains("Keychain"))
    #expect(KeychainWriter.defaultService == "Mimi Gemini API Key")
    #expect(KeychainWriter.defaultAccount == "default")
    #expect(OnboardingCopy.chromeHelperExplanation.contains("実際の通信"))
    #expect(OnboardingCopy.chromeHelperExplanation.contains("接続完了にはしません"))
    #expect(OnboardingCopy.chromeHelperExplanation.contains("自動"))
    #expect(OnboardingCopy.prepareChromeConnection.contains("ページを開いてパスをコピー"))
    #expect(OnboardingCopy.prepareChromeConnectionRunning.contains("Chrome設定"))
    #expect(OnboardingCopy.chromeManualConfirmation.contains("安全確認"))
    #expect(OnboardingCopy.chromeManualConfirmation.contains("再接続"))
    let chromeCopy = OnboardingCopy.copy(for: .japanese)
    #expect(chromeCopy.chromeInstallSteps.count == 4)
    #expect(chromeCopy.chromeInstallSteps[0].contains("拡張機能ページ"))
    #expect(chromeCopy.chromeInstallSteps[0].contains("コピー"))
    #expect(chromeCopy.chromeInstallSteps[1].contains("デベロッパー モード"))
    #expect(chromeCopy.chromeInstallSteps[1].contains("パッケージ化されていない拡張機能を読み込む"))
    #expect(chromeCopy.chromeInstallSteps[2].contains("ピン"))
    #expect(chromeCopy.chromeInstallSteps[3].contains("実接続"))
    #expect(chromeCopy.chromePathCopied.contains("コピー済み"))
    #expect(OnboardingCopy.copy(for: .japanese).chromePinInstruction.contains("自動で確認"))
    #expect(OnboardingCopy.copy(for: .japanese).messageChromeInstallPending.contains("完了にはなりません"))
    #expect(OnboardingCopy.copy(for: .japanese).messageChromeSetupOpening.contains("chrome://extensions/"))
    #expect(OnboardingCopy.copy(for: .japanese).messageChromeSetupOpenFailed.contains("chrome://extensions/"))
    #expect(OnboardingCopy.chromeTroubleshootingTitle == "うまくいかないとき")
    #expect(!OnboardingCopy.chromeHelperExplanation.contains("必要なら"))
}

@Test func englishOnboardingCopyIsNaturalAccurateAndSecretFree() {
    let english = OnboardingCopy.copy(for: .english)
    let copy = [
        english.setupSummary,
        english.apiKeyExplanation,
        english.accountGuidance,
        english.paidPathGuidance,
        english.guidedKeySteps,
        english.replaceKeyGuidance,
        english.trustExplanation,
        english.safetyExplanation,
        english.freeKeyNoMonthlyLimit,
        english.chromeHelperExplanation,
        english.prepareChromeConnection,
        english.prepareChromeConnectionRunning,
        english.chromeManualConfirmation,
        english.chromeConnectionReady,
        english.chromePinInstruction,
        english.chromePinDetected,
        english.chromeTroubleshootingTitle,
        english.keychainHelpTitle,
        english.keychainLocationValue,
        english.keychainPasswordsAppNote,
        english.finalStepThree
    ].joined(separator: "\n")

    #expect(english.languageControlLabel == "Display language")
    #expect(english.headerTitle == "Mimi Setup for Chrome")
    #expect(english.apiKeyTitle == "Prepare Google Translation")
    #expect(english.apiKeyExplanation.hasPrefix("If Google AI Studio is new to you"))
    #expect(!english.apiKeyExplanation.prefix(30).contains("API"))
    #expect(copy.contains("AI live interpretation audio"))
    #expect(copy.contains("does not replace the original speaker's voice"))
    #expect(copy.contains("Google account"))
    #expect(copy.contains("required boxes"))
    #expect(copy.contains("Continue"))
    #expect(copy.contains("API keys page"))
    #expect(copy.contains("free Gemini API key"))
    #expect(copy.contains("copy button"))
    #expect(copy.contains("paste it here"))
    #expect(copy.contains("paid Google Cloud API path"))
    #expect(copy.contains("Mimi never turns on paid billing by itself"))
    #expect(copy.contains("Only if your key has billing enabled"))
    #expect(copy.contains("optional monthly time guide"))
    #expect(copy.contains("macOS Keychain"))
    #expect(copy.contains("not in the Chrome extension"))
    #expect(copy.contains("chat"))
    #expect(copy.contains(".env"))
    #expect(copy.contains("Free keys do not need a Mimi monthly cap"))
    #expect(copy.contains("Choose the language you want to hear"))
    #expect(copy.contains("automatically installs the helper"))
    #expect(copy.contains("real request from the Chrome extension"))
    #expect(copy.contains("Chrome requires the user"))
    #expect(copy.contains("checks completion automatically"))
    #expect(english.optionalSettingsLabel == "Optional")
    #expect(english.googleKeyReady.contains("saved in Keychain"))
    #expect(english.changeGoogleKey.contains("replace"))
    #expect(copy.contains("Keychain Access"))
    #expect(copy.contains("Passwords app"))
    #expect(english.prepareChromeConnection.contains("open page and copy path"))
    #expect(english.prepareChromeConnectionRunning.contains("Starting Chrome setup"))
    #expect(english.chromeInstallSteps.count == 4)
    #expect(english.chromeInstallSteps[0].contains("extensions page"))
    #expect(english.chromeInstallSteps[0].contains("Open"))
    #expect(english.chromeInstallSteps[1].contains("Load unpacked"))
    #expect(english.chromeInstallSteps[2].contains("pin Mimi"))
    #expect(english.chromeInstallSteps[3].contains("real connection event"))
    #expect(english.messageChromeSetupOpening.contains("chrome://extensions/"))
    #expect(english.messageChromeSetupOpenFailed.contains("chrome://extensions/"))
    #expect(english.chromeTroubleshootingTitle == "If setup does not work")
    #expect(!copy.contains("Japanese audio"))
    #expect(!copy.contains("AI" + "za"))
    #expect(!copy.contains("GEMINI_" + "API_" + "KEY="))
}

@Test func releaseDisplayLanguageDefaultsToEnglishAndKeepsJapaneseAvailable() {
    #expect(SetupDisplayLanguage.releaseDefault == .english)
    #expect(OnboardingCopy.copy(for: .english).languageControlLabel == "Display language")
    #expect(OnboardingCopy.copy(for: .japanese).languageControlLabel == "表示言語")
}

@Test func setupWindowPlacementStartsNearTopOfVisibleScreen() {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let windowSize = CGSize(width: 860, height: 620)

    let origin = SetupWindowPlacement.defaultOrigin(windowSize: windowSize, visibleFrame: visibleFrame)

    #expect(origin.x == 290)
    #expect(origin.y == 208)
    #expect(origin.y > visibleFrame.midY - windowSize.height / 2)
    #expect(visibleFrame.contains(CGPoint(x: origin.x, y: origin.y)))
    #expect(visibleFrame.contains(CGPoint(x: origin.x + windowSize.width, y: origin.y + windowSize.height)))
}

@Test func setupWindowPlacementPersistsOnlyRoundedOrigin() throws {
    let suiteName = "mimi-window-placement-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let placement = SetupWindowPlacement(defaults: defaults)

    placement.save(origin: CGPoint(x: 123.4, y: 567.6))

    #expect(placement.savedOrigin() == CGPoint(x: 123, y: 568))
}

@Test func setupWindowPlacementReusesSavedOriginInsideVisibleScreen() throws {
    let suiteName = "mimi-window-placement-reuse-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let placement = SetupWindowPlacement(defaults: defaults)
    let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let windowSize = CGSize(width: 400, height: 300)

    placement.save(origin: CGPoint(x: 250, y: 260))

    #expect(placement.preferredOrigin(windowSize: windowSize, visibleFrame: visibleFrame) == CGPoint(x: 250, y: 260))
}

@Test func setupWindowPlacementClampsOutOfScreenSavedOrigin() throws {
    let suiteName = "mimi-window-placement-clamp-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let placement = SetupWindowPlacement(defaults: defaults)
    let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    let windowSize = CGSize(width: 400, height: 300)

    placement.save(origin: CGPoint(x: 900, y: -100))

    #expect(placement.preferredOrigin(windowSize: windowSize, visibleFrame: visibleFrame) == CGPoint(x: 592, y: 8))
}

private func makeTemporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mimi-app-core-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeServerStatus(
    serverReady: Bool,
    extensionVerified: Bool,
    toolbarPinned: Bool? = nil
) throws -> ServerStatus {
    let pinState = toolbarPinned ?? extensionVerified
    let data = """
    {
      "ok": true,
      "service": "jp-dub-local-server",
      "mode": "real",
      "activeSessions": 0,
      "realModeReady": \(serverReady),
      "allowedExtensionOriginConfigured": \(serverReady),
      "allowedExtensionId": "oknekoaclmnljnlpmffphpiflcdeibgg",
      "extensionConnection": {
        "verified": \(extensionVerified),
        "lastSeenAt": \(extensionVerified ? "\"2026-07-10T03:00:00.000Z\"" : "null"),
        "isOnToolbar": \(pinState),
        "installedAt": \(extensionVerified ? "\"2026-07-10T02:58:00.000Z\"" : "null"),
        "toolbarChangedAt": \(pinState ? "\"2026-07-10T02:59:00.000Z\"" : "null"),
        "popupOpenedAt": \(pinState ? "\"2026-07-10T03:00:00.000Z\"" : "null")
      },
      "setupProgress": {
        "listeningStarted": false,
        "listeningStartedAt": null
      }
    }
    """.data(using: .utf8)!
    return try JSONDecoder().decode(ServerStatus.self, from: data)
}

private func makeSetupPaths() -> MimiPaths {
    let root = URL(fileURLWithPath: "/tmp/mimi-setup-runner-test")
    return MimiPaths(
        root: root,
        extensionDirectory: root.appendingPathComponent("extension"),
        localServerDirectory: root.appendingPathComponent("local-server"),
        nativeHostDirectory: root.appendingPathComponent("native-host"),
        envFileURL: root.appendingPathComponent(".env"),
        usageFileURL: root.appendingPathComponent("usage.json"),
        runtimeEnvironment: [:]
    )
}

private func createFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

private final class FakeKeychain: KeychainAccessing {
    var addStatuses: [OSStatus]
    var updateStatuses: [OSStatus]
    var copyStatus: OSStatus
    private(set) var addedPasswords: [String] = []
    private(set) var updatedPasswords: [String] = []
    private(set) var updateQueries: [[String: Any]] = []

    init(
        addStatuses: [OSStatus] = [errSecSuccess],
        updateStatuses: [OSStatus] = [errSecSuccess],
        copyStatus: OSStatus = errSecItemNotFound
    ) {
        self.addStatuses = addStatuses
        self.updateStatuses = updateStatuses
        self.copyStatus = copyStatus
    }

    func add(_ query: [String: Any]) -> OSStatus {
        addedPasswords.append(password(from: query))
        return addStatuses.isEmpty ? errSecSuccess : addStatuses.removeFirst()
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateQueries.append(query)
        updatedPasswords.append(password(from: attributes))
        return updateStatuses.isEmpty ? errSecSuccess : updateStatuses.removeFirst()
    }

    func copyMatching(_ query: [String: Any]) -> OSStatus {
        copyStatus
    }

    private func password(from values: [String: Any]) -> String {
        guard let data = values[kSecValueData as String] as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private actor StatusSequence {
    private var statuses: [ServerStatus]
    private var count = 0

    init(_ statuses: [ServerStatus]) {
        self.statuses = statuses
    }

    func next() throws -> ServerStatus {
        guard !statuses.isEmpty else { throw ServerStatusError.notReady }
        count += 1
        return statuses.removeFirst()
    }

    func fetchCount() -> Int {
        count
    }
}

private final class FakeSetupCommandRunner: SetupCommandRunning {
    private let failingScript: String?
    private(set) var scripts: [String] = []
    private(set) var arguments: [[String]] = []
    private(set) var environments: [[String: String]] = []

    init(failingScript: String? = nil) {
        self.failingScript = failingScript
    }

    func runNodeScript(
        _ script: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> CommandResult {
        scripts.append(script)
        self.arguments.append(arguments)
        environments.append(environment)
        return CommandResult(
            command: script,
            exitCode: script == failingScript ? 1 : 0,
            output: script == failingScript ? "expected test failure" : "ok"
        )
    }
}
