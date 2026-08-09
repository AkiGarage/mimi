import Foundation
import XCTest
@testable import MimiForMac

final class SafetyTests: XCTestCase {
    func testRuntimeSafetySettingsPersistAcrossStoreRecreation() throws {
        let suiteName = "MimiRuntimeSettingsTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = MimiRuntimeSettingsStore(defaults: suite)

        XCTAssertEqual(store.load(), MimiRuntimeSettings())
        store.save(MimiRuntimeSettings(
            autoStopMinutes: 45,
            paidProtectionEnabled: true,
            paidLimitMinutes: 90,
            targetLanguageCode: "fr"
        ))

        XCTAssertEqual(
            MimiRuntimeSettingsStore(defaults: suite).load(),
            MimiRuntimeSettings(
                autoStopMinutes: 45,
                paidProtectionEnabled: true,
                paidLimitMinutes: 90,
                targetLanguageCode: "fr"
            )
        )
    }

    func testRuntimeSettingsNormalizeUnsupportedTargetLanguageToJapanese() {
        XCTAssertEqual(MimiRuntimeSettings(targetLanguageCode: "not-supported").targetLanguageCode, "ja")
    }

    func testTargetLanguageCatalogMatchesCurrentGeminiCoverageAndDefaultsToJapanese() {
        XCTAssertEqual(MimiTargetLanguage.defaultCode, "ja")
        XCTAssertEqual(MimiTargetLanguage.supported.count, 79)
        XCTAssertTrue(MimiTargetLanguage.supportedCodes.contains("en"))
        XCTAssertTrue(MimiTargetLanguage.supportedCodes.contains("es"))
        XCTAssertTrue(MimiTargetLanguage.supportedCodes.contains("zh-Hans"))
        XCTAssertTrue(MimiTargetLanguage.supportedCodes.contains("zh-Hant"))
    }

    func testTargetLanguageDisplayNamesDistinguishScriptAndRegionVariants() {
        let locale = Locale(identifier: "ja")
        XCTAssertNotEqual(
            MimiTargetLanguage(code: "zh-Hans").displayName(in: locale),
            MimiTargetLanguage(code: "zh-Hant").displayName(in: locale)
        )
        XCTAssertNotEqual(
            MimiTargetLanguage(code: "pt-BR").displayName(in: locale),
            MimiTargetLanguage(code: "pt-PT").displayName(in: locale)
        )
    }

    func testDisplayLanguageDefaultsToSystemAndSupportsExplicitJapaneseAndEnglish() {
        XCTAssertEqual(MimiDisplayLanguage.defaultValue, .system)
        XCTAssertEqual(
            MimiDisplayLanguage.system.locale(systemIdentifier: "en-GB").language.languageCode?.identifier,
            "en"
        )
        XCTAssertEqual(
            MimiDisplayLanguage.japanese.locale(systemIdentifier: "en-GB").language.languageCode?.identifier,
            "ja"
        )
        XCTAssertEqual(
            MimiDisplayLanguage.english.locale(systemIdentifier: "ja-JP").language.languageCode?.identifier,
            "en"
        )
    }

    func testDisplayLanguagePreferenceDoesNotChangeTranslatedAudioLanguage() throws {
        let suiteName = "MimiDisplayLanguageTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = MimiRuntimeSettingsStore(defaults: suite)

        store.save(MimiRuntimeSettings(targetLanguageCode: "fr"))
        suite.set(MimiDisplayLanguage.english.rawValue, forKey: MimiDisplayLanguage.storageKey)

        XCTAssertEqual(store.load().targetLanguageCode, "fr")
    }

    func testLocalizedStringsResolveInJapaneseAndEnglish() {
        XCTAssertEqual(
            MimiLocalization.string(.settingsDisplayLanguage, locale: Locale(identifier: "ja")),
            "表示言語"
        )
        XCTAssertEqual(
            MimiLocalization.string(.settingsDisplayLanguage, locale: Locale(identifier: "en")),
            "Display language"
        )
        XCTAssertEqual(
            MimiLocalization.formatted(.minutesValue, locale: Locale(identifier: "en"), 30),
            "30 min"
        )
    }

    func testEveryInterfaceStringHasJapaneseAndEnglishTranslations() {
        let locales = [Locale(identifier: "ja"), Locale(identifier: "en")]

        for key in MimiLocalizationKey.allCases {
            for locale in locales {
                XCTAssertNotEqual(
                    MimiLocalization.string(key, locale: locale),
                    key.rawValue,
                    "Missing \(locale.identifier) translation for \(key.rawValue)"
                )
            }
        }
    }

    func testAutoStopUsesThirtyMinuteDefaultAndOnlyAudioSendingTime() {
        let clock = TestMonotonicClock()
        let timer = AutoStopTimer(clock: clock)

        timer.start()
        clock.advance(by: 1_000)
        XCTAssertEqual(timer.activeAudioSeconds, 0, accuracy: 0.001)

        timer.beginAudioSending()
        clock.advance(by: 1_799)
        XCTAssertFalse(timer.shouldStop)
        timer.endAudioSending()
        clock.advance(by: 10_000)
        XCTAssertFalse(timer.shouldStop)

        timer.beginAudioSending()
        clock.advance(by: 1)
        XCTAssertTrue(timer.shouldStop)
        XCTAssertEqual(timer.limitMinutes, 30)
    }

    func testAutoStopLimitIsClampedToOneThroughOneHundredTwentyMinutes() {
        let clock = TestMonotonicClock()
        let timer = AutoStopTimer(limitMinutes: 0, clock: clock)
        XCTAssertEqual(timer.limitMinutes, 1)
        timer.setLimitMinutes(121)
        XCTAssertEqual(timer.limitMinutes, 120)
        timer.setLimitMinutes(42)
        XCTAssertEqual(timer.limitMinutes, 42)
    }

    func testAutoStopResetsForEachExplicitStartAndCanStartAgainAfterStop() {
        let clock = TestMonotonicClock()
        let timer = AutoStopTimer(limitMinutes: 1, clock: clock)

        timer.start()
        timer.beginAudioSending()
        clock.advance(by: 60)
        XCTAssertTrue(timer.shouldStop)
        timer.stop()

        timer.start()
        XCTAssertFalse(timer.shouldStop)
        timer.beginAudioSending()
        clock.advance(by: 60)
        XCTAssertTrue(timer.shouldStop)
    }

    func testPaidProtectionIsDisabledByDefaultAndFreeModeHasNoMimiMonthlyLimit() {
        let clock = TestMonotonicClock()
        let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 1_751_500_000))
        let free = PaidUsageGuard(store: InMemoryPaidUsageStore(), monotonicClock: clock, wallClock: wallClock)

        XCTAssertFalse(free.isProtectionEnabled)
        XCTAssertNil(free.remainingAudioSeconds)
        free.start()
        free.beginAudioSending()
        clock.advance(by: 10_000)
        free.endAudioSending()
        XCTAssertFalse(free.shouldStop)
        XCTAssertNil(free.remainingAudioSeconds)
    }

    func testPaidProtectionDefaultsToThirtyMinutesAndCountsOnlySendingAudio() {
        let clock = TestMonotonicClock()
        let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 1_751_500_000))
        let guarder = PaidUsageGuard(
            protectionEnabled: true,
            store: InMemoryPaidUsageStore(),
            monotonicClock: clock,
            wallClock: wallClock
        )

        XCTAssertTrue(guarder.isProtectionEnabled)
        XCTAssertEqual(guarder.limitMinutes, 30)
        guarder.start()
        clock.advance(by: 900)
        guarder.beginAudioSending()
        clock.advance(by: 1_799)
        XCTAssertFalse(guarder.shouldStop)
        guarder.endAudioSending()
        XCTAssertEqual(guarder.usedAudioSeconds, 1_799, accuracy: 0.001)
        XCTAssertEqual(guarder.remainingAudioSeconds ?? -1, 1, accuracy: 0.001)
        guarder.beginAudioSending()
        clock.advance(by: 1)
        XCTAssertTrue(guarder.shouldStop)
    }

    func testPaidUsagePersistsAcrossRestartAndCrashCheckpoint() {
        let store = InMemoryPaidUsageStore()
        let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 1_751_500_000))
        let firstClock = TestMonotonicClock()
        let first = PaidUsageGuard(protectionEnabled: true, store: store, monotonicClock: firstClock, wallClock: wallClock)
        first.start()
        first.beginAudioSending()
        firstClock.advance(by: 120)
        _ = first.checkpoint()

        let restarted = PaidUsageGuard(
            protectionEnabled: true,
            store: store,
            monotonicClock: TestMonotonicClock(),
            wallClock: wallClock
        )
        XCTAssertEqual(restarted.usedAudioSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(restarted.remainingAudioSeconds ?? -1, 1_680, accuracy: 0.001)
    }

    func testPaidUsageRollsOverOnlyWhenWallClockReachesANewerMonth() {
        let store = InMemoryPaidUsageStore()
        let clock = TestMonotonicClock()
        let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 1_751_500_000))
        let guarder = PaidUsageGuard(protectionEnabled: true, store: store, monotonicClock: clock, wallClock: wallClock)
        guarder.start(); guarder.beginAudioSending(); clock.advance(by: 200); guarder.endAudioSending()
        XCTAssertEqual(guarder.usedAudioSeconds, 200, accuracy: 0.001)

        wallClock.date = Date(timeIntervalSince1970: 1_754_200_000)
        let nextMonth = PaidUsageGuard(protectionEnabled: true, store: store, monotonicClock: TestMonotonicClock(), wallClock: wallClock)
        XCTAssertEqual(nextMonth.usedAudioSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(nextMonth.remainingAudioSeconds ?? -1, 1_800, accuracy: 0.001)
    }

    func testWallClockRollbackNeverIncreasesPaidAllowance() {
        let store = InMemoryPaidUsageStore()
        let wallClock = TestWallClock(date: Date(timeIntervalSince1970: 1_751_500_000))
        let firstClock = TestMonotonicClock()
        let first = PaidUsageGuard(protectionEnabled: true, store: store, monotonicClock: firstClock, wallClock: wallClock)
        first.start(); first.beginAudioSending(); firstClock.advance(by: 600); first.endAudioSending()

        wallClock.date = Date(timeIntervalSince1970: 1_748_900_000)
        let rolledBack = PaidUsageGuard(protectionEnabled: true, store: store, monotonicClock: TestMonotonicClock(), wallClock: wallClock)
        XCTAssertEqual(rolledBack.usedAudioSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(rolledBack.remainingAudioSeconds ?? -1, 1_200, accuracy: 0.001)
    }

    func testApplicationSupportStoreUsesAtomicJSONAndDedicatedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimi-safety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("usage.json")
        let store = ApplicationSupportPaidUsageStore(fileURL: file)
        let state = PaidUsageState(monthIdentifier: "2026-07", usedAudioSeconds: 123)
        try store.save(state)
        XCTAssertEqual(try store.load(), state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("tmp").path))
    }

    func testSafeDiagnosticsAreBoundedAndNeverRetainSensitiveValues() throws {
        let diagnostics = SafeDiagnostics(maxEvents: 2, maxBytes: 1_500)
        diagnostics.record(
            state: "listening",
            durationSeconds: 3.5,
            audioFormat: SafeAudioFormat(sampleRate: 16_000, channels: 1, sampleFormat: "pcm_s16le"),
            bufferCount: 3,
            queueDepth: 1,
            errorCode: "https://example.invalid/live?key=SECRET_API_KEY"
        )
        diagnostics.record(state: "connecting", queueDepth: 2, errorCode: "quota exceeded")
        diagnostics.record(state: "not-a-real-process-title", queueDepth: 3, errorCode: "transcript: never persist this")

        XCTAssertEqual(diagnostics.snapshot().count, 2)
        let data = try XCTUnwrap(diagnostics.encodedData())
        XCTAssertLessThanOrEqual(data.count, 1_500)
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(output.contains("SECRET_API_KEY"))
        XCTAssertFalse(output.contains("example.invalid"))
        XCTAssertFalse(output.contains("transcript"))
        XCTAssertFalse(output.contains("not-a-real-process-title"))
        XCTAssertTrue(output.contains("quota"))
    }
}

private final class TestMonotonicClock: MonotonicClock, @unchecked Sendable {
    private(set) var current: TimeInterval = 0

    func now() -> TimeInterval { current }

    func advance(by seconds: TimeInterval) {
        current += seconds
    }
}

private final class TestWallClock: WallClock, @unchecked Sendable {
    var date: Date

    init(date: Date) { self.date = date }

    func now() -> Date { date }
}
