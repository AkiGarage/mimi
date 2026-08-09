import AppKit
import Foundation
import MimiForMac
import SwiftUI

@MainActor
private final class LastExternalApplicationTracker: NSObject {
    private let workspace: NSWorkspace
    private let currentProcessID = ProcessInfo.processInfo.processIdentifier
    private(set) var processID: Int32?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        if let frontmost = workspace.frontmostApplication,
           frontmost.processIdentifier != currentProcessID {
            processID = frontmost.processIdentifier
        }
        super.init()
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              application.processIdentifier != currentProcessID else { return }
        processID = application.processIdentifier
    }
}

@MainActor
final class MimiForMacViewModel: ObservableObject {
    @Published private(set) var state: MimiUIState
    @Published private(set) var sources: [AudioSource] = []
    @Published private(set) var selectedSource: AudioSource?
    @Published private(set) var hasCredential: Bool
    @Published private(set) var isLoadingSources = false
    @Published private(set) var remainingSeconds: TimeInterval
    @Published private(set) var lastMetrics = CaptureMetrics()
    @Published var translatedVolume: Double = 0.8 {
        didSet { playback?.volume = Float(translatedVolume) }
    }
    @Published var originalVolume: Double = 0.35 {
        didSet { sourcePlayback?.volume = Float(originalVolume) }
    }
    @Published var targetLanguageCode: String {
        didSet {
            let normalized = MimiTargetLanguage.normalizedCode(targetLanguageCode)
            if targetLanguageCode != normalized {
                targetLanguageCode = normalized
                return
            }
            persistRuntimeSettings()
        }
    }
    @Published var playbackRate: Double {
        didSet {
            let normalized = MimiPlaybackRate.normalized(playbackRate)
            if playbackRate != normalized {
                playbackRate = normalized
                return
            }
            playbackRateProvider.update(normalized)
            playback?.refreshPlaybackRate()
            persistRuntimeSettings()
        }
    }
    @Published var autoStopMinutes: Int = AutoStopTimer.defaultLimitMinutes {
        didSet {
            let clamped = AutoStopTimer.clampMinutes(autoStopMinutes)
            if autoStopMinutes != clamped {
                autoStopMinutes = clamped
                return
            }
            autoStopTimer?.setLimitMinutes(clamped)
            updateRemainingTime()
            persistRuntimeSettings()
        }
    }
    @Published var paidProtectionEnabled = false {
        didSet { persistRuntimeSettings() }
    }
    @Published var paidLimitMinutes = PaidUsageGuard.defaultLimitMinutes {
        didSet {
            let clamped = max(1, paidLimitMinutes)
            if paidLimitMinutes != clamped {
                paidLimitMinutes = clamped
                return
            }
            paidUsageGuard?.setLimitMinutes(clamped)
            persistRuntimeSettings()
        }
    }
    @Published var keyDraft = ""
    @Published var isSettingsPresented = false
    @Published var isSourcePickerPresented = false

    private let credentialStore: KeychainCredentialStore
    private let sourceProvider: any AudioSourceProviding
    private let runtimeSettingsStore: MimiRuntimeSettingsStore
    private let playbackRateProvider: ManualPlaybackRateProvider
    private var stateMachine: ListeningStateMachine
    private var autoStopTimer: AutoStopTimer?
    private var paidUsageGuard: PaidUsageGuard?
    private var playback: TranslatedAudioPlayer?
    private var sourcePlayback: SourceAudioPlayer?
    private var pipeline: ListeningPipelineCoordinator?
    private var startRequestGate = MimiStartRequestGate()
    private var pipelineMonitorTask: Task<Void, Never>?
    private var sourceContextMonitorTask: Task<Void, Never>?
    private var sourceContextRestartTask: Task<Void, Never>?
    private var selectedSourceWasAutomatic = false
    private var sourceDetectionID: UUID?
    private var isAutomaticHandoffInProgress = false
    private var translationContextRestartPolicy = TranslationContextRestartPolicy()
    private let lastExternalApplication = LastExternalApplicationTracker()

    init(
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        sourceProvider: any AudioSourceProviding = ScreenCaptureKitSourceProvider(),
        runtimeSettingsStore: MimiRuntimeSettingsStore = MimiRuntimeSettingsStore()
    ) {
        self.credentialStore = credentialStore
        self.sourceProvider = sourceProvider
        self.runtimeSettingsStore = runtimeSettingsStore
        let runtimeSettings = runtimeSettingsStore.load()
        self.playbackRateProvider = ManualPlaybackRateProvider(
            initialRate: runtimeSettings.playbackRate
        )
        self.autoStopMinutes = runtimeSettings.autoStopMinutes
        self.paidProtectionEnabled = runtimeSettings.paidProtectionEnabled
        self.paidLimitMinutes = runtimeSettings.paidLimitMinutes
        self.targetLanguageCode = runtimeSettings.targetLanguageCode
        self.playbackRate = runtimeSettings.playbackRate
        let configured = credentialStore.containsCredential()
        self.hasCredential = configured
        self.state = configured ? .idleNoSource : .needsSetup
        self.remainingSeconds = TimeInterval(runtimeSettings.autoStopMinutes * 60)
        self.stateMachine = ListeningStateMachine(isSetupComplete: configured)
    }

    func selectedSourceName(locale: Locale) -> String {
        selectedSource?.displayName
            ?? MimiLocalization.string(.sourceDefaultName, locale: locale)
    }

    func targetLanguages(in locale: Locale) -> [MimiTargetLanguage] {
        MimiTargetLanguage.supported.sorted {
            $0.displayName(in: locale).localizedStandardCompare($1.displayName(in: locale))
                == .orderedAscending
        }
    }

    func targetLanguageDisplayName(in locale: Locale) -> String {
        MimiTargetLanguage(code: targetLanguageCode).displayName(in: locale)
    }

    func selectedSourceSubtitle(locale: Locale) -> String {
        guard let selectedSource else {
            return MimiLocalization.string(.sourcePlaceholder, locale: locale)
        }
        switch selectedSource.kind {
        case .application:
            if !state.isActive, selectedSourceWasAutomatic {
                return MimiLocalization.string(.sourcePrevious, locale: locale)
            }
            let windows = AudioSourceCatalog(sources: sources).windows(for: selectedSource)
            if windows.count == 1 {
                return MimiLocalization.formatted(
                    .sourceTranslatingOne,
                    locale: locale,
                    windows[0].displayName
                )
            }
            if windows.count > 1 {
                return MimiLocalization.formatted(
                    .sourceTranslatingMultiple,
                    locale: locale,
                    windows.count
                )
            }
            return selectedSource.isBrowserApplication
                ? MimiLocalization.string(.sourceBrowserUnknown, locale: locale)
                : MimiLocalization.string(.sourceApplicationAudio, locale: locale)
        case .window:
            let applicationName = sources.first {
                $0.kind == .application && $0.processID == selectedSource.processID
            }?.displayName
            let detail = MimiLocalization.string(
                selectedSource.isBrowserWindow ? .sourceBrowserWindow : .sourceWindowOnly,
                locale: locale
            )
            return applicationName.map {
                MimiLocalization.formatted(
                    .sourceApplicationDetail,
                    locale: locale,
                    $0,
                    detail
                )
            } ?? detail
        case .display:
            return MimiLocalization.string(.sourceDisplay, locale: locale)
        case .system:
            return MimiLocalization.string(.sourceSystem, locale: locale)
        }
    }

    var canControlOriginalVolume: Bool {
        selectedSource?.supportsOriginalVolumeControl == true
    }

    var showsManualSourceControl: Bool {
        if case .error(.multipleAudio) = state { return true }
        return false
    }

    var originalVolumeControllableAlternativeName: String? {
        guard let selectedSource,
              !selectedSource.supportsOriginalVolumeControl else { return nil }
        return AudioSourceCatalog(sources: sources)
            .originalVolumeControllableSource(for: selectedSource)?
            .displayName
    }

    func primaryActionTitle(locale: Locale) -> String {
        let key: MimiLocalizationKey = switch state {
        case .needsSetup: .actionSetup
        case .idleNoSource, .idleReady: .actionStart
        case .sourceEnded, .autoStopReached, .error: .actionListenAgain
        case .paidLimitReached: .actionShowSettings
        case .detectingSource: .actionDetecting
        case .connecting, .listening, .reconnecting: .actionStop
        case .requestingPermission: .actionOpenSettings
        case .stopping: .actionStopping
        }
        return MimiLocalization.string(key, locale: locale)
    }

    var statusColor: Color {
        switch state {
        case .listening: .green
        case .detectingSource, .connecting, .reconnecting, .requestingPermission: .orange
        case .error, .paidLimitReached: .red
        case .sourceEnded, .autoStopReached: .blue
        default: .secondary
        }
    }

    var remainingTimeText: String {
        let seconds = max(0, Int(remainingSeconds.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func performPrimaryAction() {
        switch state {
        case .needsSetup, .paidLimitReached: isSettingsPresented = true
        case .idleNoSource: startListening()
        case .idleReady, .autoStopReached: startListening()
        case .sourceEnded: startListening()
        case .error(let error):
            if error == .permission { openSystemAudioSettings() }
            else if error == .credential || error == .billing { isSettingsPresented = true }
            else if error == .multipleAudio { presentSourcePicker() }
            else if selectedSource == nil { startListening() }
            else { startListening() }
        case .detectingSource: break
        case .requestingPermission: openSystemAudioSettings()
        case .connecting, .listening, .reconnecting: stopListening()
        case .stopping: break
        }
    }

    func presentSourcePicker() {
        guard !state.isActive else { return }
        if case .error(.multipleAudio) = state, !sources.isEmpty {
            isSourcePickerPresented = true
            isLoadingSources = false
            return
        }
        isSourcePickerPresented = true
        isLoadingSources = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let discovered = try await sourceProvider.availableSources()
                sources = discovered
                isLoadingSources = false
            } catch let error as CaptureError {
                isLoadingSources = false
                isSourcePickerPresented = false
                state = error.requiresSystemSettings ? .requestingPermission : .error(map(error))
            } catch {
                isLoadingSources = false
                isSourcePickerPresented = false
                state = .error(.unknown)
            }
        }
    }

    func selectSource(_ source: AudioSource) {
        guard !state.isActive else { return }
        sourceDetectionID = nil
        selectedSource = source
        selectedSourceWasAutomatic = false
        isSourcePickerPresented = false
        Task { [weak self] in
            guard let self else { return }
            await stateMachine.selectSource()
            state = .idleReady
        }
    }

    func switchToOriginalVolumeControllableSource() {
        guard !state.isActive,
              let selectedSource,
              let controllableSource = AudioSourceCatalog(sources: sources)
                .originalVolumeControllableSource(for: selectedSource),
              controllableSource.id != selectedSource.id else { return }
        selectSource(controllableSource)
    }

    func clearSource() {
        guard !state.isActive else { return }
        sourceDetectionID = nil
        selectedSource = nil
        selectedSourceWasAutomatic = false
        Task { [weak self] in
            guard let self else { return }
            await stateMachine.clearSource()
            state = .idleNoSource
        }
    }

    func saveKey() {
        let candidate = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            state = .error(.credential)
            return
        }
        do {
            try credentialStore.save(candidate)
            keyDraft.removeAll(keepingCapacity: false)
            hasCredential = true
            state = selectedSource == nil ? .idleNoSource : .idleReady
            Task { [weak self] in
                guard let self else { return }
                await stateMachine.completeSetup()
            }
        } catch {
            keyDraft.removeAll(keepingCapacity: false)
            state = .error(.credential)
        }
    }

    func deleteKey() {
        do {
            sourceDetectionID = nil
            try credentialStore.remove()
            keyDraft.removeAll(keepingCapacity: false)
            hasCredential = false
            state = .needsSetup
        } catch {
            state = .error(.credential)
        }
    }

    func clearKeyDraft() { keyDraft.removeAll(keepingCapacity: false) }

    func openSystemAudioSettings() {
        state = .requestingPermission
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func startListening() {
        guard hasCredential else {
            state = .needsSetup
            isSettingsPresented = true
            return
        }
        guard !state.isActive else { return }
        guard let source = selectedSource, !selectedSourceWasAutomatic else {
            detectSourceAndStart()
            return
        }
        beginListening(with: source)
    }

    private func beginListening(with source: AudioSource) {
        guard startRequestGate.begin(isActive: state.isActive) else { return }
        Task { [weak self] in
            guard let self else { return }
            startRequestGate.complete()
            sourceDetectionID = nil
            selectedSourceWasAutomatic = true
            state = .connecting
            lastMetrics = CaptureMetrics()
            remainingSeconds = TimeInterval(autoStopMinutes * 60)
            let credential: String
            do {
                credential = try credentialStore.load()
            } catch {
                state = .error(.credential)
                return
            }
            guard let backend = makeBackend(for: source) else {
                state = .error(.permission)
                return
            }

            let timer = AutoStopTimer(limitMinutes: autoStopMinutes)
            let usageGuard = PaidUsageGuard(
                mode: paidProtectionEnabled ? .paidProtected : .free,
                limitMinutes: paidLimitMinutes
            )
            let player = TranslatedAudioPlayer(playbackRateProvider: playbackRateProvider)
            player.volume = Float(translatedVolume)
            let monitor: SourceAudioPlayer?
            if source.supportsOriginalVolumeControl {
                let newMonitor = SourceAudioPlayer()
                newMonitor.volume = Float(originalVolume)
                monitor = newMonitor
            } else {
                monitor = nil
            }
            let machine = ListeningStateMachine(isSetupComplete: true)
            let coordinator = ListeningPipelineCoordinator(
                capture: CaptureSession(backend: backend),
                credential: GeminiCredential(credential),
                targetLanguageCode: targetLanguageCode,
                transportFactory: { credential, _ in
                    URLSessionGeminiLiveTransport(credential: credential)
                },
                player: player,
                sourceMonitor: monitor,
                stateMachine: machine,
                autoStopTimer: timer,
                paidUsageGuard: usageGuard
            )

            stateMachine = machine
            autoStopTimer = timer
            paidUsageGuard = usageGuard
            playback = player
            sourcePlayback = monitor
            pipeline = coordinator
            do {
                _ = try await coordinator.start(source: source)
                beginPipelineMonitoring(coordinator)
                beginSourceContextMonitoring(for: source, coordinator: coordinator)
            } catch {
                state = .error(mapPipelineError(error))
                await coordinator.stop()
            }
        }
    }

    private func detectSourceAndStart() {
        guard !state.isActive else { return }
        guard #available(macOS 14.2, *) else {
            state = .error(.permission)
            return
        }
        let detectionID = UUID()
        sourceDetectionID = detectionID
        selectedSource = nil
        selectedSourceWasAutomatic = false
        state = .detectingSource
        Task { [weak self] in
            guard let self else { return }
            do {
                let discovered = try await sourceProvider.availableSources()
                guard sourceDetectionID == detectionID, state == .detectingSource else { return }
                let applications = discovered.filter { $0.kind == .application }
                sources = discovered
                switch try CoreAudioActiveAudioTargetDetector().detect(
                    applications: applications,
                    frontmostProcessID: lastExternalApplication.processID
                ) {
                case .selected(let source):
                    guard sourceDetectionID == detectionID else { return }
                    selectedSource = source
                    selectedSourceWasAutomatic = true
                    await stateMachine.selectSource()
                    guard sourceDetectionID == detectionID else { return }
                    state = .idleReady
                    beginListening(with: source)
                case .none:
                    sourceDetectionID = nil
                    state = .error(.noAudio)
                case .ambiguous(let candidates):
                    sourceDetectionID = nil
                    let candidateProcessIDs = Set(candidates.compactMap(\.processID))
                    sources = discovered.filter { source in
                        if source.kind == .application { return candidates.contains(source) }
                        return source.processID.map(candidateProcessIDs.contains) == true
                    }
                    state = .error(.multipleAudio)
                }
            } catch let error as CaptureError {
                guard sourceDetectionID == detectionID else { return }
                sourceDetectionID = nil
                state = error.requiresSystemSettings ? .requestingPermission : .error(map(error))
            } catch {
                guard sourceDetectionID == detectionID else { return }
                sourceDetectionID = nil
                state = .error(.unknown)
            }
        }
    }

    func stopListening() {
        guard let pipeline else { return }
        state = .stopping
        sourceContextMonitorTask?.cancel()
        sourceContextMonitorTask = nil
        sourceContextRestartTask?.cancel()
        sourceContextRestartTask = nil
        translationContextRestartPolicy.reset()
        Task {
            await pipeline.stop()
        }
    }

    private func beginPipelineMonitoring(_ coordinator: ListeningPipelineCoordinator) {
        pipelineMonitorTask?.cancel()
        pipelineMonitorTask = Task { [weak self, weak coordinator] in
            while !Task.isCancelled {
                guard let self, let coordinator, self.pipeline === coordinator else { return }
                let machineState = await coordinator.currentState()
                if self.isAutomaticHandoffInProgress {
                    self.lastMetrics = coordinator.captureMetrics
                    self.updateRemainingTime()
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
                self.state = self.map(machineState)
                self.lastMetrics = coordinator.captureMetrics
                self.updateRemainingTime()
                if !machineState.isActive,
                   machineState != .connecting,
                   machineState != .selectingSource {
                    switch machineState {
                    case .ready, .autoStopReached, .paidLimitReached, .sourceEnded, .failed:
                        self.pipeline = nil
                        self.playback = nil
                        self.sourcePlayback = nil
                        self.autoStopTimer = nil
                        self.paidUsageGuard = nil
                        self.sourceContextMonitorTask?.cancel()
                        self.sourceContextMonitorTask = nil
                        self.sourceContextRestartTask?.cancel()
                        self.sourceContextRestartTask = nil
                        self.translationContextRestartPolicy.reset()
                        return
                    default:
                        break
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func beginSourceContextMonitoring(
        for source: AudioSource,
        coordinator: ListeningPipelineCoordinator
    ) {
        sourceContextMonitorTask?.cancel()
        guard source.kind == .application else { return }
        translationContextRestartPolicy.reset()
        sourceContextRestartTask?.cancel()
        let monitor = ActiveTranslationContextMonitor(
            sourceProvider: sourceProvider,
            playbackContextProvider: QuickTimePlaybackContextProvider(),
            refreshInterval: .milliseconds(500)
        )
        sourceContextMonitorTask = Task { [weak self, weak coordinator] in
            var handoffPolicy = AutomaticAudioTargetHandoffPolicy()
            for await snapshot in monitor.snapshots(for: source) {
                guard !Task.isCancelled,
                      let self,
                      let coordinator,
                      self.pipeline === coordinator,
                      self.selectedSource?.id == source.id else { return }
                self.sources = snapshot.contextSources
                self.observeTranslationContext(
                    source: source,
                    contextSources: snapshot.contextSources,
                    coordinator: coordinator
                )

                guard #available(macOS 14.2, *) else { continue }
                do {
                    let applications = snapshot.discoveredSources.filter { $0.kind == .application }
                    let activeApplications = try CoreAudioActiveAudioTargetDetector()
                        .activeApplications(applications: applications)
                    let now = TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
                    if let newTarget = handoffPolicy.nextTarget(
                        current: source,
                        activeApplications: activeApplications,
                        now: now
                    ) {
                        await self.performAutomaticHandoff(
                            from: source,
                            to: newTarget,
                            coordinator: coordinator
                        )
                        return
                    }
                } catch {
                    handoffPolicy.reset()
                }
            }
        }
    }

    private func performAutomaticHandoff(
        from oldSource: AudioSource,
        to newSource: AudioSource,
        coordinator: ListeningPipelineCoordinator
    ) async {
        guard !Task.isCancelled,
              !isAutomaticHandoffInProgress,
              state != .stopping,
              pipeline === coordinator,
              selectedSource?.id == oldSource.id,
              newSource.id != oldSource.id else { return }

        isAutomaticHandoffInProgress = true
        sourceContextRestartTask?.cancel()
        translationContextRestartPolicy.reset()
        selectedSource = newSource
        selectedSourceWasAutomatic = true
        sources = [newSource]
        state = .connecting

        do {
            _ = try await coordinator.switchSource(to: newSource)
            guard !Task.isCancelled,
                  state != .stopping,
                  pipeline === coordinator else {
                isAutomaticHandoffInProgress = false
                await coordinator.stop()
                return
            }
            isAutomaticHandoffInProgress = false
            beginSourceContextMonitoring(for: newSource, coordinator: coordinator)
        } catch {
            isAutomaticHandoffInProgress = false
            if Task.isCancelled || state == .stopping {
                await coordinator.stop()
                return
            }
            state = .error(mapPipelineError(error))
            await coordinator.stop()
        }
    }

    private func observeTranslationContext(
        source: AudioSource,
        contextSources: [AudioSource],
        coordinator: ListeningPipelineCoordinator
    ) {
        guard contextSources.count == 2, let window = contextSources.last else { return }
        let normalizedTitle = window.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let signature = "\(source.id)\u{001F}\(normalizedTitle)"

        // Browser window titles describe the currently visible tab, not the tab
        // producing process-level audio. Keep the title fresh for display, but
        // never tear down a healthy Gemini session from that visual-only signal.
        switch translationContextRestartPolicy.observe(
            signature,
            allowsSessionRestart: !source.isBrowserApplication
        ) {
        case .none:
            return
        case .cancelPending:
            sourceContextRestartTask?.cancel()
            sourceContextRestartTask = nil
            return
        case .schedule:
            break
        }

        sourceContextRestartTask?.cancel()
        sourceContextRestartTask = Task { [weak self, weak coordinator] in
            do {
                try await Task.sleep(for: .milliseconds(750))
            } catch {
                return
            }
            guard let self, let coordinator,
                  self.selectedSource?.id == source.id,
                  self.state.isActive,
                  self.translationContextRestartPolicy.beginRestart(for: signature) else { return }
            await self.performTranslationContextRestart(
                source: source,
                signature: signature,
                coordinator: coordinator
            )
        }
    }

    private func performTranslationContextRestart(
        source: AudioSource,
        signature: String,
        coordinator: ListeningPipelineCoordinator
    ) async {
        guard !Task.isCancelled,
              !isAutomaticHandoffInProgress,
              state != .stopping,
              pipeline === coordinator,
              selectedSource?.id == source.id else { return }

        isAutomaticHandoffInProgress = true
        state = .connecting
        do {
            _ = try await coordinator.restartSource(source)
            guard !Task.isCancelled,
                  state != .stopping,
                  pipeline === coordinator else {
                isAutomaticHandoffInProgress = false
                await coordinator.stop()
                return
            }
            isAutomaticHandoffInProgress = false
            translationContextRestartPolicy.finishRestart(for: signature)
            sourceContextRestartTask = nil
        } catch {
            isAutomaticHandoffInProgress = false
            translationContextRestartPolicy.finishRestart(for: signature)
            sourceContextRestartTask = nil
            if Task.isCancelled || state == .stopping {
                await coordinator.stop()
                return
            }
            state = .error(mapPipelineError(error))
            await coordinator.stop()
        }
    }

    private func map(_ state: ListeningAppState) -> MimiUIState {
        switch state {
        case .needsSetup: .needsSetup
        case .idle: .idleNoSource
        case .selectingSource: .idleNoSource
        case .ready: .idleReady
        case .connecting: .connecting
        case .listening: .listening
        case .reconnecting: .reconnecting
        case .stopping: .stopping
        case .autoStopReached: .autoStopReached
        case .paidLimitReached: .paidLimitReached
        case .sourceEnded: .sourceEnded
        case .failed(let failure): .error(map(failure))
        }
    }

    private func map(_ failure: ListeningFailure) -> MimiUIError {
        switch failure {
        case .permission: .permission
        case .credential: .credential
        case .network: .network
        case .quota: .quota
        case .billing: .billing
        case .noAudio: .noAudio
        case .unknown: .unknown
        }
    }

    private func mapPipelineError(_ error: Error) -> MimiUIError {
        if let error = error as? CaptureError { return map(error) }
        if let error = error as? GeminiLiveSessionError {
            switch error.category {
            case .authentication: return .credential
            case .quota: return .quota
            case .billing: return .billing
            case .transientNetwork: return .network
            case .invalidAudio, .protocolViolation: return .noAudio
            default: return .unknown
            }
        }
        return .unknown
    }

    private func makeBackend(for source: AudioSource) -> (any CaptureBackend)? {
        if source.kind == .application || source.kind == .system {
            guard #available(macOS 14.2, *) else { return nil }
            return CoreAudioProcessTapBackend()
        }
        if source.kind == .window { return ScreenCaptureKitBackend() }
        return nil
    }

    private func updateRemainingTime() {
        remainingSeconds = autoStopTimer?.remainingAudioSeconds ?? TimeInterval(autoStopMinutes * 60)
    }

    private func persistRuntimeSettings() {
        runtimeSettingsStore.save(MimiRuntimeSettings(
            autoStopMinutes: autoStopMinutes,
            paidProtectionEnabled: paidProtectionEnabled,
            paidLimitMinutes: paidLimitMinutes,
            targetLanguageCode: targetLanguageCode,
            playbackRate: playbackRate
        ))
    }

    private func map(_ error: CaptureError) -> MimiUIError {
        switch error {
        case .permissionDenied: .permission
        case .sourceEnded, .processNotFound: .noAudio
        case .system: .unknown
        case .alreadyRunning, .notRunning, .backendUnavailable, .unsupportedFormat, .unknown: .unknown
        }
    }
}
