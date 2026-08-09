import Foundation

public struct AudioSourceGroup: Identifiable, Equatable, Sendable {
    public let application: AudioSource
    public let windows: [AudioSource]

    public var id: String { application.id }
}

/// Presentation-ready grouping that keeps private window titles in memory only.
public struct AudioSourceCatalog: Equatable, Sendable {
    public let recommendedGroups: [AudioSourceGroup]
    public let otherGroups: [AudioSourceGroup]
    public let systemSource: AudioSource?

    public init(sources: [AudioSource]) {
        let applications = sources.filter { $0.kind == .application }
        let windows = sources.filter { $0.kind == .window }
        let groups = applications.map { application in
            AudioSourceGroup(
                application: application,
                windows: windows
                    .filter { $0.processID == application.processID }
                    .sorted(by: Self.sourceNameOrder)
            )
        }
        .sorted { lhs, rhs in
            let leftRank = Self.recommendationRank(lhs.application.bundleIdentifier)
            let rightRank = Self.recommendationRank(rhs.application.bundleIdentifier)
            if leftRank != rightRank { return leftRank < rightRank }
            return Self.sourceNameOrder(lhs.application, rhs.application)
        }

        recommendedGroups = groups.filter {
            Self.recommendationRank($0.application.bundleIdentifier) < Int.max
        }
        otherGroups = groups.filter {
            Self.recommendationRank($0.application.bundleIdentifier) == Int.max
        }
        systemSource = sources.first { $0.kind == .system }
    }

    /// Returns the same source when it is controllable, or the owning app for a window.
    /// macOS only provides a safe mute/replay boundary at app or system scope.
    public func originalVolumeControllableSource(for source: AudioSource) -> AudioSource? {
        if source.supportsOriginalVolumeControl { return source }
        guard source.kind == .window, let processID = source.processID else { return nil }
        return (recommendedGroups + otherGroups)
            .map(\.application)
            .first { $0.processID == processID }
    }

    /// Visible, titled windows belonging to an application. These are presentation
    /// context only: process-level audio cannot be attributed to one of these windows.
    public func windows(for application: AudioSource) -> [AudioSource] {
        guard application.kind == .application else { return [] }
        return (recommendedGroups + otherGroups)
            .first { $0.application.id == application.id }?
            .windows ?? []
    }

    private static func sourceNameOrder(_ lhs: AudioSource, _ rhs: AudioSource) -> Bool {
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func recommendationRank(_ bundleIdentifier: String?) -> Int {
        guard let bundleIdentifier else { return Int.max }
        return recommendedBundleIdentifiers.firstIndex(of: bundleIdentifier) ?? Int.max
    }

    private static let recommendedBundleIdentifiers = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.apple.QuickTimePlayerX",
        "com.apple.Music",
        "com.apple.podcasts"
    ]
}
