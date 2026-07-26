import Foundation
import XCTest
@testable import MimiForMac

final class GeminiLiveTranslationTests: XCTestCase {
    func testTransportUsesHeaderForTokenCreationAndKeepsCredentialOutOfURLs() throws {
        let credential = "test-only-credential"
        let tokenRequest = URLSessionGeminiLiveTransport.tokenRequest(for: GeminiCredential(credential))
        let socketRequest = URLSessionGeminiLiveTransport.webSocketRequest(
            endpoint: URLSessionGeminiLiveTransport.defaultEndpoint,
            token: "short-lived-test-token"
        )

        XCTAssertFalse(try XCTUnwrap(tokenRequest.url?.absoluteString).contains(credential))
        XCTAssertEqual(tokenRequest.value(forHTTPHeaderField: "x-goog-api-key"), credential)
        XCTAssertFalse(try XCTUnwrap(socketRequest.url?.absoluteString).contains(credential))
        XCTAssertNil(URLComponents(url: try XCTUnwrap(socketRequest.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name.caseInsensitiveCompare("key") == .orderedSame })
        XCTAssertEqual(socketRequest.value(forHTTPHeaderField: "Authorization"), "Token short-lived-test-token")
    }

    func testTransientNetworkErrorDoesNotAlsoEmitTerminalFailedState() async throws {
        let transport = FakeGeminiTransport()
        let recorder = EventRecorder()
        let session = GeminiLiveTranslationSession(
            credential: GeminiCredential("test-only-credential"),
            transportFactory: { _, _ in transport },
            onEvent: { recorder.append($0) }
        )

        try await session.start()
        transport.emit(.failed(.network))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(recorder.errors().last?.category, .transientNetwork)
        XCTAssertFalse(recorder.states().contains(.failed))
    }

    func testSetupUsesAudioJapaneseAndAutoSourceThenFlushesQueuedPCM() async throws {
        let transport = FakeGeminiTransport()
        let session = GeminiLiveTranslationSession(
            credential: GeminiCredential(opaqueValue: "test-only-credential"),
            transportFactory: { _, _ in transport }
        )

        try await session.start()
        let setup = try XCTUnwrap(transport.sentMessages().first).jsonObject()
        let setupBody = try XCTUnwrap(setup["setup"] as? [String: Any])
        XCTAssertEqual(setupBody["model"] as? String, "models/gemini-3.5-live-translate-preview")
        let generation = try XCTUnwrap(setupBody["generationConfig"] as? [String: Any])
        XCTAssertEqual(generation["responseModalities"] as? [String], ["AUDIO"])
        let translation = try XCTUnwrap(generation["translationConfig"] as? [String: Any])
        XCTAssertEqual(translation["targetLanguageCode"] as? String, "ja")
        XCTAssertEqual(translation["echoTargetLanguage"] as? Bool, false)
        XCTAssertNil(translation["sourceLanguageCode"])

        let input = PCMChunk(samples: [1, -2, 0x1234])
        let accepted = try await session.sendAudio(input)
        XCTAssertTrue(accepted)
        XCTAssertEqual(transport.sentMessages().count, 1)

        transport.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(20))
        let audioMessage = try XCTUnwrap(transport.sentMessages().last).jsonObject()
        let realtime = try XCTUnwrap(audioMessage["realtimeInput"] as? [String: Any])
        let audio = try XCTUnwrap(realtime["audio"] as? [String: Any])
        XCTAssertEqual(audio["mimeType"] as? String, "audio/pcm;rate=16000")
        let encoded = try XCTUnwrap(audio["data"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), Data([1, 0, 0xfe, 0xff, 0x34, 0x12]))

        await session.stop()
    }

    func testSetupUsesSelectedTargetLanguageAndKeepsSourceAutomatic() async throws {
        let transport = FakeGeminiTransport()
        let session = GeminiLiveTranslationSession(
            credential: GeminiCredential(opaqueValue: "test-only-credential"),
            targetLanguageCode: "es",
            transportFactory: { _, _ in transport }
        )

        try await session.start()
        let setup = try XCTUnwrap(transport.sentMessages().first).jsonObject()
        let setupBody = try XCTUnwrap(setup["setup"] as? [String: Any])
        let generation = try XCTUnwrap(setupBody["generationConfig"] as? [String: Any])
        let translation = try XCTUnwrap(generation["translationConfig"] as? [String: Any])
        XCTAssertEqual(translation["targetLanguageCode"] as? String, "es")
        XCTAssertNil(translation["sourceLanguageCode"])
    }

    func testParsesInline24KHzAudioAndRejectsMalformedAudio() async throws {
        let transport = FakeGeminiTransport()
        let recorder = EventRecorder()
        let session = GeminiLiveTranslationSession(
            credential: GeminiCredential(opaqueValue: "test-only-credential"),
            transportFactory: { _, _ in transport },
            onEvent: { recorder.append($0) }
        )

        try await session.start()
        transport.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(10))

        let output = Data([0x34, 0x12, 0xcc, 0xfe])
        let message = """
        {"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\(output.base64EncodedString())"}}]}}}
        """
        transport.emit(.message(Data(message.utf8)))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(recorder.audio().first, PCMChunk(sampleRate: 24_000, channels: 1, samples: [0x1234, -308]))

        transport.emit(.message(Data(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQ=="}}]}}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(recorder.errors().contains { $0.category == .protocolViolation })
        await session.stop()
    }

    func testOldGenerationCannotDeliverAudioOrErrorsAfterReconnect() async throws {
        let first = FakeGeminiTransport()
        let second = FakeGeminiTransport()
        let transports = TransportSequence([first, second])
        let recorder = EventRecorder()
        let session = GeminiLiveTranslationSession(
            credential: GeminiCredential(opaqueValue: "test-only-credential"),
            transportFactory: { _, generation in transports.transport(for: generation) },
            onEvent: { recorder.append($0) }
        )

        try await session.start()
        first.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(10))
        try await session.reconnect()
        second.emit(.message(Data(#"{"setupComplete":{}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(10))

        let oldOutput = Data([1, 0])
        first.emit(.message(Data("{\"serverContent\":{\"modelTurn\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"audio/pcm;rate=24000\",\"data\":\"\(oldOutput.base64EncodedString())\"}}]}}}".utf8)))
        first.emit(.failed(.network))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(recorder.audio().isEmpty)
        XCTAssertFalse(recorder.errors().contains { $0.category == .transientNetwork })
        await session.stop()
    }

    func testGoAwayIsAReconnectHookAndResumptionHandleIsUsedByNextGeneration() async throws {
        let first = FakeGeminiTransport()
        let second = FakeGeminiTransport()
        let transports = TransportSequence([first, second])
        let hook = ReconnectRecorder()
        let session = GeminiLiveTranslationSession(
            credential: GeminiCredential(opaqueValue: "test-only-credential"),
            transportFactory: { _, generation in transports.transport(for: generation) },
            onReconnectSuggested: { hook.append($0) }
        )

        try await session.start()
        first.emit(.message(Data(#"{"sessionResumptionUpdate":{"newHandle":"opaque-resumption-token","resumable":true},"goAway":{"timeLeft":"2.5s"}}"#.utf8)))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(hook.values(), [2.5])

        try await session.reconnect()
        let setup = try XCTUnwrap(second.sentMessages().first).jsonObject()
        let setupBody = try XCTUnwrap(setup["setup"] as? [String: Any])
        let resumption = try XCTUnwrap(setupBody["sessionResumption"] as? [String: Any])
        XCTAssertEqual(resumption["handle"] as? String, "opaque-resumption-token")
        await session.stop()
    }

    func testAuthQuotaAndBillingErrorsAreTerminalAndDoNotReconnect() async throws {
        for (errorObject, expected) in [
            (#"{"error":{"code":401,"status":"UNAUTHENTICATED","message":"bad key"}}"#, GeminiLiveErrorCategory.authentication),
            (#"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","message":"quota"}}"#, GeminiLiveErrorCategory.quota),
            (#"{"error":{"code":402,"status":"FAILED_PRECONDITION","message":"billing required"}}"#, GeminiLiveErrorCategory.billing)
        ] {
            let transport = FakeGeminiTransport()
            let recorder = EventRecorder()
            let session = GeminiLiveTranslationSession(
                credential: GeminiCredential(opaqueValue: "test-only-credential"),
                transportFactory: { _, _ in transport },
                onEvent: { recorder.append($0) }
            )
            try await session.start()
            transport.emit(.message(Data(errorObject.utf8)))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(recorder.errors().last?.category, expected)
            XCTAssertEqual(session.currentState, .failed)
            XCTAssertEqual(transport.connectCount, 1)
            let accepted = try await session.sendAudio(PCMChunk(samples: [1]))
            XCTAssertFalse(accepted)
        }
    }
}

private final class FakeGeminiTransport: GeminiLiveTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (GeminiTransportEvent) -> Void)?
    private var messages = [Data]()
    private(set) var connectCount = 0

    func connect(onEvent: @escaping @Sendable (GeminiTransportEvent) -> Void) async throws {
        locked {
            callback = onEvent
            connectCount += 1
        }
    }

    func send(_ message: Data) async throws {
        locked { messages.append(message) }
    }

    func close() async {}

    func emit(_ event: GeminiTransportEvent) {
        lock.lock(); let callback = self.callback; lock.unlock()
        callback?(event)
    }

    func sentMessages() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class TransportSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [FakeGeminiTransport]

    init(_ values: [FakeGeminiTransport]) { self.values = values }

    func transport(for generation: UInt64) -> FakeGeminiTransport {
        lock.lock(); defer { lock.unlock() }
        return values[Int(generation - 1)]
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [GeminiLiveSessionEvent]()

    func append(_ event: GeminiLiveSessionEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func audio() -> [PCMChunk] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { event in
            if case .audio(let chunk) = event { return chunk }
            return nil
        }
    }

    func errors() -> [GeminiLiveSessionError] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { event in
            if case .error(let error) = event { return error }
            return nil
        }
    }

    func states() -> [GeminiLiveSessionState] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { event in
            if case .stateChanged(let state) = event { return state }
            return nil
        }
    }
}

private final class ReconnectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [TimeInterval]()

    func append(_ value: TimeInterval) {
        lock.lock(); recorded.append(value); lock.unlock()
    }

    func values() -> [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}
