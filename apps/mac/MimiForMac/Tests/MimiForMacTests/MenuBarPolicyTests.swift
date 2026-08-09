import Foundation
import XCTest
@testable import MimiForMac

final class MenuBarPolicyTests: XCTestCase {
    func testPresentationUsesStateTextSymbolAndOnlyListeningPulses() {
        let locale = Locale(identifier: "ja")
        let listening = MimiMenuBarPresentationPolicy.presentation(
            for: .listening,
            locale: locale
        )

        XCTAssertEqual(listening.title, "翻訳音声を再生中")
        XCTAssertEqual(listening.value, "映像より数秒遅れて聞こえます。")
        XCTAssertEqual(listening.symbolName, "waveform")
        XCTAssertTrue(listening.shouldPulse)

        let staticStates: [MimiUIState] = [
            .needsSetup,
            .idleNoSource,
            .idleReady,
            .detectingSource,
            .requestingPermission,
            .connecting,
            .reconnecting,
            .stopping,
            .sourceEnded,
            .autoStopReached,
            .paidLimitReached,
            .error(.network)
        ]
        XCTAssertTrue(staticStates.allSatisfy {
            !MimiMenuBarPresentationPolicy.presentation(for: $0, locale: locale).shouldPulse
        })
    }

    func testPulseUsesSlowCycleAndReduceMotionIsAlwaysStatic() {
        XCTAssertEqual(MimiMenuBarPulsePolicy.cycleDuration, 2.4, accuracy: 0.000_001)
        XCTAssertEqual(
            MimiMenuBarPulsePolicy.opacity(
                elapsed: 0,
                shouldPulse: true,
                reduceMotion: false
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MimiMenuBarPulsePolicy.opacity(
                elapsed: 1.2,
                shouldPulse: true,
                reduceMotion: false
            ),
            0.72,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MimiMenuBarPulsePolicy.opacity(
                elapsed: 2.4,
                shouldPulse: true,
                reduceMotion: false
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MimiMenuBarPulsePolicy.opacity(
                elapsed: 1.2,
                shouldPulse: true,
                reduceMotion: true
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            MimiMenuBarPulsePolicy.opacity(
                elapsed: 1.2,
                shouldPulse: false,
                reduceMotion: false
            ),
            1,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testCommandsRouteToExactlyOneSharedHandler() {
        var calls = [MimiMenuBarCommand: Int]()
        let router = MimiMenuBarCommandRouter(
            openWindow: { calls[.openWindow, default: 0] += 1 },
            performPrimaryAction: { calls[.primaryAction, default: 0] += 1 },
            showSettings: { calls[.settings, default: 0] += 1 },
            quit: { calls[.quit, default: 0] += 1 }
        )

        for command in MimiMenuBarCommand.allCases {
            router.perform(command)
        }

        XCTAssertEqual(calls, [
            .openWindow: 1,
            .primaryAction: 1,
            .settings: 1,
            .quit: 1
        ])
    }

    func testStartRequestGateCoalescesWindowAndMenuStarts() {
        var gate = MimiStartRequestGate()

        XCTAssertTrue(gate.begin(isActive: false))
        XCTAssertFalse(gate.begin(isActive: false))

        gate.complete()
        XCTAssertFalse(gate.begin(isActive: true))
        XCTAssertTrue(gate.begin(isActive: false))
    }
}
