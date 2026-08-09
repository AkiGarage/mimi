import XCTest
@testable import MimiForMac

final class ActiveTranslationContextMonitorTests: XCTestCase {
    func testUpdatesVisibleBrowserWindowWhileApplicationCaptureContinues() async throws {
        let chrome = AudioSource(
            id: "pid:42",
            displayName: "Google Chrome",
            kind: .application,
            processID: 42,
            bundleIdentifier: "com.google.Chrome"
        )
        let xVideo = AudioSource(
            id: "window:101",
            displayName: "OpenAI video / X",
            kind: .window,
            processID: 42,
            windowID: 101,
            bundleIdentifier: "com.google.Chrome"
        )
        let youtubeVideo = AudioSource(
            id: "window:101",
            displayName: "Lecture / YouTube",
            kind: .window,
            processID: 42,
            windowID: 101,
            bundleIdentifier: "com.google.Chrome"
        )
        let provider = SequencedSourceProvider([
            [chrome, xVideo],
            [chrome, youtubeVideo]
        ])
        let monitor = ActiveTranslationContextMonitor(
            sourceProvider: provider,
            refreshInterval: .milliseconds(1)
        )
        var iterator = monitor.updates(for: chrome).makeAsyncIterator()

        let firstUpdate = await iterator.next()
        let secondUpdate = await iterator.next()
        let first = try XCTUnwrap(firstUpdate)
        let second = try XCTUnwrap(secondUpdate)

        XCTAssertEqual(first.map(\.displayName), ["Google Chrome", "OpenAI video / X"])
        XCTAssertEqual(second.map(\.displayName), ["Google Chrome", "Lecture / YouTube"])
    }

    func testQuickTimeContextKeepsOnlyThePlayingDocument() async throws {
        let quickTime = AudioSource(
            id: "pid:77",
            displayName: "QuickTime Player",
            kind: .application,
            processID: 77,
            bundleIdentifier: "com.apple.QuickTimePlayerX"
        )
        let pausedMovie = AudioSource(
            id: "window:201",
            displayName: "Music.mov",
            kind: .window,
            processID: 77,
            windowID: 201,
            bundleIdentifier: "com.apple.QuickTimePlayerX"
        )
        let playingMovie = AudioSource(
            id: "window:202",
            displayName: "AI lecture.mp4",
            kind: .window,
            processID: 77,
            windowID: 202,
            bundleIdentifier: "com.apple.QuickTimePlayerX"
        )
        let provider = SequencedSourceProvider([[quickTime, pausedMovie, playingMovie]])
        let playbackContext = FakePlaybackWindowContextProvider(names: ["AI lecture.mp4"])
        let monitor = ActiveTranslationContextMonitor(
            sourceProvider: provider,
            playbackContextProvider: playbackContext,
            refreshInterval: .milliseconds(1)
        )
        var iterator = monitor.updates(for: quickTime).makeAsyncIterator()

        let nextUpdate = await iterator.next()
        let update = try XCTUnwrap(nextUpdate)

        XCTAssertEqual(update.map(\.displayName), ["QuickTime Player", "AI lecture.mp4"])
    }
}

private actor SequencedSourceProvider: AudioSourceProviding {
    private var snapshots: [[AudioSource]]

    init(_ snapshots: [[AudioSource]]) {
        self.snapshots = snapshots
    }

    func availableSources() async throws -> [AudioSource] {
        guard snapshots.count > 1 else { return snapshots[0] }
        return snapshots.removeFirst()
    }
}

private struct FakePlaybackWindowContextProvider: PlaybackWindowContextProviding {
    let names: [String]

    func playingWindowNames(for application: AudioSource) async -> [String]? {
        names
    }
}
