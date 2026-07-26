import XCTest
@testable import MimiForMac

final class ActiveAudioTargetDetectorTests: XCTestCase {
    private let safari = AudioSource(
        id: "pid:42",
        displayName: "Safari",
        kind: .application,
        processID: 42,
        bundleIdentifier: "com.apple.Safari"
    )
    private let chrome = AudioSource(
        id: "pid:84",
        displayName: "Google Chrome",
        kind: .application,
        processID: 84,
        bundleIdentifier: "com.google.Chrome"
    )

    func testSelectsOnlyApplicationWhoseHelperIsProducingAudio() {
        let decision = ActiveAudioTargetResolver.resolve(
            applications: [safari, chrome],
            activeProcessIDs: [1_719],
            frontmostProcessID: nil,
            parentOf: { $0 == 1_719 ? 84 : nil }
        )

        XCTAssertEqual(decision, .selected(chrome))
    }

    func testPrefersFrontmostApplicationWhenSeveralAreProducingAudio() {
        let decision = ActiveAudioTargetResolver.resolve(
            applications: [safari, chrome],
            activeProcessIDs: [42, 1_719],
            frontmostProcessID: 84,
            parentOf: { $0 == 1_719 ? 84 : nil }
        )

        XCTAssertEqual(decision, .selected(chrome))
    }

    func testReturnsAmbiguousInsteadOfMixingSeveralBackgroundApplications() {
        let decision = ActiveAudioTargetResolver.resolve(
            applications: [safari, chrome],
            activeProcessIDs: [42, 84],
            frontmostProcessID: 999,
            parentOf: { _ in nil }
        )

        XCTAssertEqual(decision, .ambiguous([chrome, safari]))
    }

    func testReturnsNoneWhenNoKnownApplicationIsProducingAudio() {
        let decision = ActiveAudioTargetResolver.resolve(
            applications: [safari, chrome],
            activeProcessIDs: [999],
            frontmostProcessID: nil,
            parentOf: { _ in nil }
        )

        XCTAssertEqual(decision, .none)
    }

    func testIgnoresWindowAndSystemCatalogEntries() {
        let window = AudioSource(
            id: "window:7",
            displayName: "Example",
            kind: .window,
            processID: 42,
            windowID: 7
        )

        let decision = ActiveAudioTargetResolver.resolve(
            applications: [.system, window, safari],
            activeProcessIDs: [42],
            frontmostProcessID: nil,
            parentOf: { _ in nil }
        )

        XCTAssertEqual(decision, .selected(safari))
    }
}
