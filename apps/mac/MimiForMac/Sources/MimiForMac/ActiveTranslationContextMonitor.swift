import Foundation

/// Optional app-specific playback metadata. `nil` means unsupported or
/// temporarily unavailable; an empty array means the app reports no playing
/// windows. Failures affect display context only and never stop translation.
public protocol PlaybackWindowContextProviding: Sendable {
    func playingWindowNames(for application: AudioSource) async -> [String]?
}

public struct ActiveTranslationContextSnapshot: Sendable, Equatable {
    public let contextSources: [AudioSource]
    public let discoveredSources: [AudioSource]

    public init(contextSources: [AudioSource], discoveredSources: [AudioSource]) {
        self.contextSources = contextSources
        self.discoveredSources = discoveredSources
    }
}

/// Refreshes presentation context for an active app-level capture without changing
/// the capture target. Source discovery failures are transient and must not stop audio.
public struct ActiveTranslationContextMonitor: Sendable {
    private let sourceProvider: any AudioSourceProviding
    private let playbackContextProvider: (any PlaybackWindowContextProviding)?
    private let refreshInterval: Duration

    public init(
        sourceProvider: any AudioSourceProviding,
        playbackContextProvider: (any PlaybackWindowContextProviding)? = nil,
        refreshInterval: Duration = .seconds(1)
    ) {
        self.sourceProvider = sourceProvider
        self.playbackContextProvider = playbackContextProvider
        self.refreshInterval = refreshInterval
    }

    public func updates(for application: AudioSource) -> AsyncStream<[AudioSource]> {
        let snapshots = snapshots(for: application)
        return AsyncStream { continuation in
            let task = Task {
                var previous: [AudioSource]?
                for await snapshot in snapshots {
                    guard !Task.isCancelled else { break }
                    if snapshot.contextSources != previous {
                        previous = snapshot.contextSources
                        continuation.yield(snapshot.contextSources)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Emits every successful refresh, including unchanged presentation
    /// context, so callers can apply time-based handoff stability policies.
    public func snapshots(for application: AudioSource) -> AsyncStream<ActiveTranslationContextSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        let discovered = try await sourceProvider.availableSources()
                        let playbackWindowNames = await playbackContextProvider?
                            .playingWindowNames(for: application)
                        continuation.yield(ActiveTranslationContextSnapshot(
                            contextSources: Self.context(
                                for: application,
                                in: discovered,
                                playbackWindowNames: playbackWindowNames
                            ),
                            discoveredSources: discovered
                        ))
                    } catch {
                        // Keep the last truthful context and retry. Display refresh
                        // failure must never interrupt capture or Gemini playback.
                    }
                    do {
                        try await Task.sleep(for: refreshInterval)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func context(
        for application: AudioSource,
        in discovered: [AudioSource],
        playbackWindowNames: [String]? = nil
    ) -> [AudioSource] {
        let currentApplication = discovered.first { source in
            guard source.kind == .application else { return false }
            if let processID = application.processID {
                return source.processID == processID
            }
            return source.bundleIdentifier == application.bundleIdentifier
        } ?? application
        let windows = AudioSourceCatalog(sources: discovered).windows(for: currentApplication)
        if let playbackWindowNames {
            let playingWindows = playbackWindowNames.map { name in
                windows.first { window in
                    normalized(window.displayName) == normalized(name)
                        || normalized(window.displayName).contains(normalized(name))
                        || normalized(name).contains(normalized(window.displayName))
                } ?? AudioSource(
                    id: "playback:\(currentApplication.id):\(name)",
                    displayName: name,
                    kind: .window,
                    processID: currentApplication.processID,
                    bundleIdentifier: currentApplication.bundleIdentifier
                )
            }
            return [currentApplication] + playingWindows
        }
        return [currentApplication] + windows
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
