import XCTest
@testable import MimiForMac

final class AutomaticTranslationTargetPolicyTests: XCTestCase {
    private let quickTime = AudioSource(
        id: "pid:42",
        displayName: "QuickTime Player",
        kind: .application,
        processID: 42,
        bundleIdentifier: "com.apple.QuickTimePlayerX"
    )
    private let chrome = AudioSource(
        id: "pid:84",
        displayName: "Google Chrome",
        kind: .application,
        processID: 84,
        bundleIdentifier: "com.google.Chrome"
    )

    func testHandoffRequiresTheOldAppToStopAndTheNewAppToRemainStable() {
        var policy = AutomaticAudioTargetHandoffPolicy(stabilityInterval: 1.0)

        XCTAssertNil(policy.nextTarget(
            current: quickTime,
            activeApplications: [quickTime, chrome],
            now: 10
        ))
        XCTAssertNil(policy.nextTarget(
            current: quickTime,
            activeApplications: [chrome],
            now: 11
        ))
        XCTAssertNil(policy.nextTarget(
            current: quickTime,
            activeApplications: [chrome],
            now: 11.9
        ))
        XCTAssertEqual(policy.nextTarget(
            current: quickTime,
            activeApplications: [chrome],
            now: 12.1
        ), chrome)
    }

    func testHandoffDoesNotGuessWhenSeveralNewAppsProduceAudio() {
        let safari = AudioSource(
            id: "pid:126",
            displayName: "Safari",
            kind: .application,
            processID: 126,
            bundleIdentifier: "com.apple.Safari"
        )
        var policy = AutomaticAudioTargetHandoffPolicy(stabilityInterval: 0)

        XCTAssertNil(policy.nextTarget(
            current: quickTime,
            activeApplications: [chrome, safari],
            now: 10
        ))
    }

    func testStableSnapshotDoesNotCancelAnInFlightTargetRestart() {
        var policy = TranslationContextRestartPolicy()

        XCTAssertEqual(policy.observe("chrome\u{001F}X video"), .none)
        XCTAssertEqual(
            policy.observe("chrome\u{001F}YouTube video"),
            .schedule("chrome\u{001F}YouTube video")
        )
        XCTAssertTrue(policy.beginRestart(for: "chrome\u{001F}YouTube video"))

        XCTAssertEqual(policy.observe("chrome\u{001F}YouTube video"), .none)
        XCTAssertTrue(policy.isRestartInProgress)
    }

    func testVisibleBrowserTabChangeDoesNotRequestSessionRestart() {
        var policy = TranslationContextRestartPolicy()

        XCTAssertEqual(
            policy.observe(
                "chrome\u{001F}YouTube video",
                allowsSessionRestart: !chrome.isBrowserApplication
            ),
            .none
        )
        XCTAssertEqual(
            policy.observe(
                "chrome\u{001F}Silent website",
                allowsSessionRestart: !chrome.isBrowserApplication
            ),
            .none
        )
        XCTAssertFalse(policy.isRestartInProgress)
    }

    func testQuickTimePlaybackTitleChangeStillRequestsSessionRestart() {
        var policy = TranslationContextRestartPolicy()

        XCTAssertEqual(
            policy.observe(
                "quicktime\u{001F}Lecture one",
                allowsSessionRestart: !quickTime.isBrowserApplication
            ),
            .none
        )
        XCTAssertEqual(
            policy.observe(
                "quicktime\u{001F}Lecture two",
                allowsSessionRestart: !quickTime.isBrowserApplication
            ),
            .schedule("quicktime\u{001F}Lecture two")
        )
    }

}
