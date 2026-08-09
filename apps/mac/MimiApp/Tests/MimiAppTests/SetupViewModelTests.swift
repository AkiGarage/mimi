import AppKit
import Foundation
import Testing
@testable import MimiAppCore
@testable import MimiApp

@Test @MainActor func startingChromeVerificationClearsStaleSuccessImmediately() {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(
        paths: nil,
        launchOptions: SetupLaunchOptions(arguments: ["Mimi", "--fresh-setup-preview"]),
        defaults: defaults
    )
    model.isChromeExtensionVerified = true
    model.isChromeConnectionReady = true

    model.prepareChromeConnection()

    #expect(!model.isChromeExtensionVerified)
    #expect(!model.isChromeConnectionReady)
    #expect(model.isChromeSetupRunning)
    #expect(model.message == .chromeSetupOpening)
    #expect(model.rows[1].state == .running)
}

@Test @MainActor func providerSelectionUsesServerCanonicalPreference() async throws {
    let suiteName = "MimiAppProviderTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var writes: [MimiProvider] = []
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false,
        statusClient: ServerStatusClient(
            fetchStatus: { throw ServerStatusError.notReady },
            writeProvider: { provider in
                writes.append(provider)
                return ProviderSettingsResponse(ok: true, preferredProvider: .openai)
            }
        )
    )

    model.apply(status: try makeServerStatus(
        serverReady: false,
        extensionVerified: false,
        toolbarPinned: false,
        preferredProvider: "gemini"
    ))
    model.selectProvider(.openai)
    try await waitUntil { !model.isProviderSaving }

    #expect(writes == [.openai])
    #expect(model.preferredProvider == .openai)
    #expect(model.canChangeProvider)
}

@Test @MainActor func staleXAIProviderStatusFallsBackToGemini() throws {
    let suiteName = "MimiAppStaleProviderTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false,
        statusClient: ServerStatusClient(fetchStatus: { throw ServerStatusError.notReady })
    )

    model.apply(status: try makeServerStatus(
        serverReady: false,
        extensionVerified: false,
        toolbarPinned: false,
        preferredProvider: "gemini"
    ))
    #expect(model.preferredProvider == .gemini)
    #expect(model.canChangeProvider)
}

@Test @MainActor func providerSelectionIsDisabledDuringActiveSession() throws {
    let suiteName = "MimiAppProviderActiveTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var didWrite = false
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false,
        statusClient: ServerStatusClient(
            fetchStatus: { throw ServerStatusError.notReady },
            writeProvider: { provider in
                didWrite = true
                return ProviderSettingsResponse(ok: true, preferredProvider: provider)
            }
        )
    )

    model.apply(status: try makeServerStatus(
        serverReady: false,
        extensionVerified: false,
        toolbarPinned: false,
        activeSessions: 1,
        preferredProvider: "gemini"
    ))
    model.selectProvider(.openai)

    #expect(model.activeSessionCount == 1)
    #expect(!model.canChangeProvider)
    #expect(model.preferredProvider == .gemini)
    #expect(!didWrite)
}

@Test @MainActor func freshSetupPreviewIgnoresPersistedListeningCompletion() {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    SetupValidationStore(defaults: defaults).markListeningStarted(true)

    let model = SetupViewModel(
        paths: nil,
        launchOptions: SetupLaunchOptions(arguments: ["Mimi", "--fresh-setup-preview"]),
        defaults: defaults,
        startsAutomaticRefresh: false
    )

    #expect(!model.hasStartedListening)
    #expect(model.rows[2].state == .notStarted)
}

@Test @MainActor func popupConnectionCannotReuseOldTranslationCompletionInFreshExperience() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let experienceStart = parseTestDate("2026-07-13T04:00:00.000Z")
    let model = SetupViewModel(
        paths: nil,
        launchOptions: SetupLaunchOptions(arguments: ["Mimi", "--fresh-setup-preview"]),
        defaults: defaults,
        startsAutomaticRefresh: false,
        now: { experienceStart }
    )
    model.hasStartedChromeSetup = true

    model.apply(status: try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: true,
        listeningStarted: true,
        listeningStartedAt: "2026-07-13T03:00:00.000Z"
    ))

    #expect(model.rows[1].state == .done)
    #expect(model.rows[2].state == .ready)
    #expect(!model.hasStartedListening)
}

@Test @MainActor func freshExperienceCompletesOnlyForNewTranslationEvent() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let experienceStart = parseTestDate("2026-07-13T04:00:00.000Z")
    let model = SetupViewModel(
        paths: nil,
        launchOptions: SetupLaunchOptions(arguments: ["Mimi", "--fresh-setup-preview"]),
        defaults: defaults,
        startsAutomaticRefresh: false,
        now: { experienceStart }
    )
    model.hasStartedChromeSetup = true

    model.apply(status: try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: true,
        listeningStarted: true,
        listeningStartedAt: "2026-07-13T04:00:01.000Z"
    ))

    #expect(model.rows[2].state == .done)
    #expect(model.hasStartedListening)
}

@Test @MainActor func chromeSetupOpensExtensionsPageAndCopiesPathBeforeBackendPreparation() async throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let paths = makeSetupPaths()
    let events = EventLog()
    let commandRunner = RecordingSetupCommandRunner(events: events)
    let launcher = FakeChromeURLLauncher(events: events)
    let clipboard = FakeClipboardWriter()
    let statuses = StatusSequence([
        try makeServerStatus(serverReady: true, extensionVerified: false, toolbarPinned: false),
        try makeServerStatus(serverReady: true, extensionVerified: true, toolbarPinned: true)
    ])
    let model = SetupViewModel(
        paths: paths,
        defaults: defaults,
        startsAutomaticRefresh: false,
        statusClient: ServerStatusClient(fetchStatus: { try await statuses.next() }),
        setupCommandRunner: commandRunner,
        chromeURLLauncher: launcher,
        clipboardWriter: clipboard
    )

    model.prepareChromeConnection()

    #expect(model.message == .chromeSetupOpening)
    #expect(model.isChromeSetupRunning)
    #expect(model.rows[1].state == .running)
    try await waitUntil { !model.isRunning }

    let entries = await events.values()
    #expect(entries.first == "open:chrome://extensions/")
    #expect(entries.contains("script:scripts/install.js"))
    #expect(await commandRunner.scripts() == [
        "scripts/install.js",
        "scripts/doctor.js",
        "scripts/stop.js",
        "scripts/start-detached.js"
    ])
    #expect(launcher.openedURLs.first?.absoluteString == "chrome://extensions/")
    #expect(clipboard.values.first == paths.extensionDirectory.path)
    #expect(model.isChromeConnectionReady)
}

@Test @MainActor func chromeSetupLaunchFailureStopsWithActionableState() async throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let paths = makeSetupPaths()
    let events = EventLog()
    let commandRunner = RecordingSetupCommandRunner(events: events)
    let launcher = FakeChromeURLLauncher(
        events: events,
        results: [.failure("Google Chrome is not installed or could not be found.")]
    )
    let clipboard = FakeClipboardWriter()
    let model = SetupViewModel(
        paths: paths,
        defaults: defaults,
        startsAutomaticRefresh: false,
        setupCommandRunner: commandRunner,
        chromeURLLauncher: launcher,
        clipboardWriter: clipboard
    )

    model.prepareChromeConnection()
    try await waitUntil { !model.isRunning }

    #expect(model.message == .chromeSetupOpenFailed("Google Chrome is not installed or could not be found."))
    #expect(model.hasChromeSetupFailure)
    #expect(model.rows[1].state == .needsAttention)
    #expect(model.chromeGuideCompletedSteps.isEmpty)
    #expect(await commandRunner.scripts().isEmpty)
    #expect(clipboard.values.first == paths.extensionDirectory.path)
}

@Test @MainActor func chromeURLLauncherUsesChromeBundleForInternalURL() async {
    let chromeAppURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    let workspace = FakeWorkspaceOpener(chromeURL: chromeAppURL)
    let launcher = SystemChromeURLLauncher(workspace: workspace)
    let url = URL(string: "chrome://extensions/")!

    let result = await launcher.openChromeURL(url)

    #expect(result.opened)
    #expect(workspace.openedURLs == [url])
    #expect(workspace.applicationURL == chromeAppURL)
    #expect(workspace.defaultOpenedURLs.isEmpty)
}

@Test @MainActor func existingValidKeyMigratesWithoutReentry() async {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var validationCalls = 0
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false,
        storedGoogleKeyExists: { true },
        existingGoogleKeyValidator: {
            validationCalls += 1
            return CommandResult(command: "diagnose-real", exitCode: 0, output: "PASS")
        }
    )

    #expect(!model.isGoogleKeyConfigured)
    await model.validateExistingGoogleKeyIfNeeded()

    #expect(validationCalls == 1)
    #expect(model.isGoogleKeyConfigured)
    #expect(model.rows[0].state == .done)
}

@Test @MainActor func verifiedChromeWithoutToolbarPinShowsPinRequiredState() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false
    )

    model.apply(status: try makeServerStatus(serverReady: true, extensionVerified: true, toolbarPinned: false))

    #expect(model.isChromeExtensionVerified)
    #expect(!model.isChromeConnectionReady)
    #expect(model.message == .chromePinRequired)
    #expect(model.rows[1].state == .needsAttention)
}

@Test @MainActor func pinnedChromeDoesNotBypassServerReadiness() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false
    )

    model.apply(status: try makeServerStatus(serverReady: false, extensionVerified: true, toolbarPinned: true))

    #expect(model.isChromeExtensionVerified)
    #expect(model.isChromePinnedConfirmed)
    #expect(!model.isChromeConnectionReady)
    #expect(model.message == .needsAttention)
    #expect(model.rows[2].state == .notStarted)
}

@Test @MainActor func startListeningStaysReadyBeforeFirstSuccessfulStart() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false
    )

    model.apply(status: try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: true,
        listeningStarted: false
    ))

    #expect(model.isChromeConnectionReady)
    #expect(model.rows[1].state == .done)
    #expect(model.rows[2].state == .ready)
}

@Test @MainActor func firstSuccessfulStartCompletesStepThreeAndPersistsIt() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false
    )

    model.apply(status: try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: true,
        listeningStarted: true
    ))

    #expect(model.rows[2].state == .done)

    let reloaded = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false
    )
    reloaded.apply(status: try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: true,
        listeningStarted: false
    ))

    #expect(reloaded.rows[2].state == .done)
}

@Test @MainActor func failedOrUnstartedSessionDoesNotCompleteStepThree() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: false
    )

    model.apply(status: try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: true,
        listeningStarted: false
    ))

    #expect(model.rows[2].state == .ready)
}

@Test @MainActor func automaticRefreshCompletesStepThreeAfterChromeStartsTranslation() async throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let statuses = StatusSequence([
        try makeServerStatus(serverReady: true, extensionVerified: true, toolbarPinned: true, listeningStarted: false),
        try makeServerStatus(serverReady: true, extensionVerified: true, toolbarPinned: true, listeningStarted: true)
    ])
    let model = SetupViewModel(
        paths: nil,
        defaults: defaults,
        startsAutomaticRefresh: true,
        statusClient: ServerStatusClient(fetchStatus: { try await statuses.next() }),
        automaticRefreshIntervalNanoseconds: 1_000_000
    )

    try await waitUntil { model.rows[2].state == .done }

    #expect(model.hasStartedListening)
    #expect(model.rows[2].state == .done)
}

@Test @MainActor func chromeGuideUsesSeparateObservedCheckpoints() throws {
    let suiteName = "MimiAppTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SetupViewModel(paths: nil, defaults: defaults, startsAutomaticRefresh: false)
    model.hasStartedChromeSetup = true

    model.apply(status: try makeServerStatus(
        serverReady: true,
        extensionVerified: true,
        toolbarPinned: false,
        installed: true,
        toolbarChanged: false,
        popupOpened: false
    ))

    #expect(model.chromeGuideCompletedSteps == [1])
    #expect(model.rows[1].state != .done)
}

private func makeServerStatus(
    serverReady: Bool,
    extensionVerified: Bool,
    toolbarPinned: Bool,
    activeSessions: Int = 0,
    preferredProvider: String? = nil,
    listeningStarted: Bool = false,
    listeningStartedAt: String? = nil,
    installed: Bool? = nil,
    toolbarChanged: Bool? = nil,
    popupOpened: Bool? = nil
) throws -> ServerStatus {
    let installedState = installed ?? extensionVerified
    let toolbarChangedState = toolbarChanged ?? toolbarPinned
    let popupOpenedState = popupOpened ?? toolbarPinned
    let providerField = preferredProvider.map { "\n      \"preferredProvider\": \"\($0)\"," } ?? ""
    let data = """
    {
      "ok": true,
      "service": "jp-dub-local-server",
      "mode": "real",
      "activeSessions": \(activeSessions),\(providerField)
      "realModeReady": \(serverReady),
      "allowedExtensionOriginConfigured": \(serverReady),
      "allowedExtensionId": "oknekoaclmnljnlpmffphpiflcdeibgg",
      "extensionConnection": {
        "verified": \(extensionVerified),
        "lastSeenAt": \(extensionVerified ? "\"2026-07-12T12:00:00.000Z\"" : "null"),
        "isOnToolbar": \(toolbarPinned),
        "installedAt": \(installedState ? "\"2026-07-12T11:58:00.000Z\"" : "null"),
        "toolbarChangedAt": \(toolbarChangedState ? "\"2026-07-12T11:59:00.000Z\"" : "null"),
        "popupOpenedAt": \(popupOpenedState ? "\"2026-07-12T12:00:00.000Z\"" : "null")
      },
      "setupProgress": {
        "listeningStarted": \(listeningStarted),
        "listeningStartedAt": \(listeningStarted ? "\"\(listeningStartedAt ?? "2026-07-13T01:00:00.000Z")\"" : "null")
      }
    }
    """.data(using: .utf8)!
    return try JSONDecoder().decode(ServerStatus.self, from: data)
}

private func makeSetupPaths() -> MimiPaths {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mimi-setup-view-model-test-\(UUID().uuidString)")
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

private func parseTestDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)!
}

@MainActor
private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    for _ in 0..<50 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for condition")
}

private actor EventLog {
    private var entries: [String] = []

    func append(_ value: String) {
        entries.append(value)
    }

    func values() -> [String] {
        entries
    }
}

@MainActor
private final class FakeChromeURLLauncher: ChromeURLLaunching {
    private let events: EventLog
    private var results: [ChromeURLLaunchResult]
    private(set) var openedURLs: [URL] = []
    private(set) var defaultOpenedURLs: [URL] = []

    init(events: EventLog, results: [ChromeURLLaunchResult] = []) {
        self.events = events
        self.results = results
    }

    func openChromeURL(_ url: URL) async -> ChromeURLLaunchResult {
        openedURLs.append(url)
        await events.append("open:\(url.absoluteString)")
        if results.isEmpty {
            return .success
        }
        return results.removeFirst()
    }

    func openDefaultURL(_ url: URL) {
        defaultOpenedURLs.append(url)
    }
}

@MainActor
private final class FakeClipboardWriter: ClipboardWriting {
    var results: [Bool]
    private(set) var values: [String] = []

    init(results: [Bool] = []) {
        self.results = results
    }

    func writeString(_ value: String) -> Bool {
        values.append(value)
        if results.isEmpty {
            return true
        }
        return results.removeFirst()
    }
}

private final class RecordingSetupCommandRunner: SetupCommandRunning {
    private let events: EventLog
    private var recordedScripts: [String] = []

    init(events: EventLog) {
        self.events = events
    }

    func runNodeScript(
        _ script: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> CommandResult {
        recordedScripts.append(script)
        await events.append("script:\(script)")
        return CommandResult(command: script, exitCode: 0, output: "ok")
    }

    func scripts() async -> [String] {
        recordedScripts
    }
}

@MainActor
private final class FakeWorkspaceOpener: WorkspaceOpening {
    let chromeURL: URL?
    var openedURLs: [URL] = []
    var defaultOpenedURLs: [URL] = []
    var applicationURL: URL?

    init(chromeURL: URL?) {
        self.chromeURL = chromeURL
    }

    func chromeApplicationURL() -> URL? {
        chromeURL
    }

    func openDefault(_ url: URL) {
        defaultOpenedURLs.append(url)
    }

    func openURLsInChrome(
        _ urls: [URL],
        applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async -> ChromeURLLaunchResult {
        openedURLs.append(contentsOf: urls)
        self.applicationURL = applicationURL
        return .success
    }
}

private actor StatusSequence {
    private var statuses: [ServerStatus]

    init(_ statuses: [ServerStatus]) {
        self.statuses = statuses
    }

    func next() throws -> ServerStatus {
        guard !statuses.isEmpty else { throw ServerStatusError.notReady }
        return statuses.removeFirst()
    }
}
