import Foundation

/// An opaque-in-practice credential container. The value is accepted only so
/// a transport can authenticate; it has no Codable representation and is never
/// written to disk by this package.
public struct GeminiCredential: Sendable {
    let opaqueValue: String

    public init(_ opaqueValue: String) { self.opaqueValue = opaqueValue }
    public init(opaqueValue: String) { self.opaqueValue = opaqueValue }
}

public enum GeminiLiveSessionState: String, Sendable, Equatable {
    case idle
    case connecting
    case translating
    case reconnecting
    case stopped
    case failed
}

public enum GeminiLiveErrorCategory: Sendable, Equatable {
    case authentication
    case quota
    case billing
    case invalidRequest
    case transientNetwork
    case protocolViolation
    case alreadyRunning
    case invalidAudio
    case stopped
    case unknown
}

public enum GeminiLiveSessionError: Error, Sendable, Equatable, LocalizedError {
    case missingCredential
    case alreadyRunning
    case authentication
    case quota
    case billing
    case invalidRequest
    case transientNetwork
    case protocolViolation
    case invalidAudio
    case stopped
    case unknown

    public var category: GeminiLiveErrorCategory {
        switch self {
        case .missingCredential, .authentication: return .authentication
        case .alreadyRunning: return .alreadyRunning
        case .quota: return .quota
        case .billing: return .billing
        case .invalidRequest: return .invalidRequest
        case .transientNetwork: return .transientNetwork
        case .protocolViolation: return .protocolViolation
        case .invalidAudio: return .invalidAudio
        case .stopped: return .stopped
        case .unknown: return .unknown
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .authentication, .missingCredential, .quota, .billing, .invalidRequest, .invalidAudio, .protocolViolation:
            return true
        case .alreadyRunning, .transientNetwork, .stopped, .unknown:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingCredential: return "Gemini credential is not configured."
        case .alreadyRunning: return "A Gemini session is already running."
        case .authentication: return "Gemini authentication failed."
        case .quota: return "Gemini quota was reached."
        case .billing: return "Gemini billing access is unavailable."
        case .invalidRequest: return "Gemini rejected the session request."
        case .transientNetwork: return "The Gemini network connection was interrupted."
        case .protocolViolation: return "Gemini returned an unsupported response."
        case .invalidAudio: return "The audio format is not supported by Gemini."
        case .stopped: return "The Gemini session is stopped."
        case .unknown: return "The Gemini session failed."
        }
    }
}

public enum GeminiLiveSessionEvent: Sendable, Equatable {
    case stateChanged(GeminiLiveSessionState)
    case setupCompleted
    case audio(PCMChunk)
    case reconnectSuggested(timeLeft: TimeInterval)
    case sessionResumptionUpdated
    case error(GeminiLiveSessionError)
}

/// One generation of a Gemini Live Translation connection. A new generation
/// owns a new transport and old transport callbacks are ignored by generation
/// number, preventing output or errors from crossing a reconnect boundary.
public final class GeminiLiveTranslationSession: @unchecked Sendable {
    public typealias TransportFactory = @Sendable (GeminiCredential, UInt64) -> any GeminiLiveTransport
    public typealias EventHandler = @Sendable (GeminiLiveSessionEvent) -> Void

    public static let model = "gemini-3.5-live-translate-preview"
    public static let defaultTargetLanguage = MimiTargetLanguage.defaultCode
    public static let inputSampleRate = 16_000
    public static let outputSampleRate = 24_000
    private static let maxQueuedChunks = 6

    private let credential: GeminiCredential
    private let targetLanguageCode: String
    private let transportFactory: TransportFactory
    private let onEvent: EventHandler
    private let onReconnectSuggested: (@Sendable (TimeInterval) -> Void)?
    private let lock = NSLock()

    private var state: GeminiLiveSessionState = .idle
    private var generationCounter: UInt64 = 0
    private var activeGeneration: UInt64?
    private var transport: (any GeminiLiveTransport)?
    private var setupComplete = false
    private var isFlushingQueuedMessages = false
    private var queuedMessages = [Data]()
    private var resumptionToken: String?

    public init(
        credential: GeminiCredential,
        targetLanguageCode: String = MimiTargetLanguage.defaultCode,
        transportFactory: @escaping TransportFactory,
        onEvent: @escaping EventHandler = { _ in },
        onReconnectSuggested: (@Sendable (TimeInterval) -> Void)? = nil
    ) {
        self.credential = credential
        self.targetLanguageCode = MimiTargetLanguage.normalizedCode(targetLanguageCode)
        self.transportFactory = transportFactory
        self.onEvent = onEvent
        self.onReconnectSuggested = onReconnectSuggested
    }

    public convenience init(
        credential: GeminiCredential,
        targetLanguageCode: String = MimiTargetLanguage.defaultCode,
        transport: any GeminiLiveTransport,
        onEvent: @escaping EventHandler = { _ in },
        onReconnectSuggested: (@Sendable (TimeInterval) -> Void)? = nil
    ) {
        self.init(
            credential: credential,
            targetLanguageCode: targetLanguageCode,
            transportFactory: { _, _ in transport },
            onEvent: onEvent,
            onReconnectSuggested: onReconnectSuggested
        )
    }

    public convenience init(
        credential: GeminiCredential,
        targetLanguageCode: String = MimiTargetLanguage.defaultCode,
        endpoint: URL = URLSessionGeminiLiveTransport.defaultEndpoint,
        onEvent: @escaping EventHandler = { _ in },
        onReconnectSuggested: (@Sendable (TimeInterval) -> Void)? = nil
    ) {
        self.init(
            credential: credential,
            targetLanguageCode: targetLanguageCode,
            transportFactory: { credential, _ in URLSessionGeminiLiveTransport(credential: credential, endpoint: endpoint) },
            onEvent: onEvent,
            onReconnectSuggested: onReconnectSuggested
        )
    }

    public var currentState: GeminiLiveSessionState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public var currentGeneration: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return activeGeneration
    }

    public func start() async throws {
        guard !credential.opaqueValue.isEmpty else {
            transitionToFailure(.missingCredential, generation: nil, transportToClose: nil)
            throw GeminiLiveSessionError.missingCredential
        }

        let (generation, newTransport): (UInt64, any GeminiLiveTransport) = try locked {
            guard activeGeneration == nil else { throw GeminiLiveSessionError.alreadyRunning }
            generationCounter &+= 1
            let generation = generationCounter
            state = .connecting
            setupComplete = false
            isFlushingQueuedMessages = false
            queuedMessages.removeAll(keepingCapacity: true)
            activeGeneration = generation
            let newTransport = transportFactory(credential, generation)
            transport = newTransport
            return (generation, newTransport)
        }
        emit(.stateChanged(.connecting))

        do {
            try await connect(newTransport, generation: generation)
        } catch let error as GeminiLiveSessionError {
            throw error
        } catch {
            let mapped = GeminiLiveSessionError.transientNetwork
            transitionToFailure(mapped, generation: generation, transportToClose: newTransport)
            throw mapped
        }
    }

    /// Replaces the current connection with a fresh generation. A server
    /// resumption handle, if received, is included in the new setup message.
    public func reconnect() async throws {
        let prepared: ((any GeminiLiveTransport)?, UInt64, any GeminiLiveTransport)? = locked {
            guard activeGeneration != nil else { return nil }
            let oldTransport = transport
            generationCounter &+= 1
            let generation = generationCounter
            state = .reconnecting
            setupComplete = false
            isFlushingQueuedMessages = false
            queuedMessages.removeAll(keepingCapacity: true)
            activeGeneration = generation
            let newTransport = transportFactory(credential, generation)
            transport = newTransport
            return (oldTransport, generation, newTransport)
        }
        guard let (oldTransport, generation, newTransport) = prepared else {
            return try await start()
        }
        emit(.stateChanged(.reconnecting))
        await oldTransport?.close()

        do {
            try await connect(newTransport, generation: generation)
        } catch let error as GeminiLiveSessionError {
            throw error
        } catch {
            let mapped = GeminiLiveSessionError.transientNetwork
            transitionToFailure(mapped, generation: generation, transportToClose: newTransport)
            throw mapped
        }
    }

    @discardableResult
    public func sendAudio(_ chunk: PCMChunk) async throws -> Bool {
        guard chunk.sampleRate == 16_000, chunk.channels == 1 else {
            throw GeminiLiveSessionError.invalidAudio
        }
        let data = try Self.makeAudioMessage(for: chunk)
        enum SendPlan { case unavailable, queued, send(UInt64, any GeminiLiveTransport) }
        let plan: SendPlan = locked {
            guard let generation = activeGeneration, let destination = transport,
                  state == .connecting || state == .translating || state == .reconnecting else {
                return .unavailable
            }
            guard setupComplete, !isFlushingQueuedMessages else {
                if queuedMessages.count == Self.maxQueuedChunks { queuedMessages.removeFirst() }
                queuedMessages.append(data)
                return .queued
            }
            return .send(generation, destination)
        }
        switch plan {
        case .unavailable: return false
        case .queued: return true
        case .send(let generation, let destination):
            do {
                try await destination.send(data)
                return true
            } catch {
                let mapped = Self.mapTransportError(error)
                transitionToFailure(mapped, generation: generation, transportToClose: destination)
                throw mapped
            }
        }
    }

    public func stop() async {
        let oldTransport: (any GeminiLiveTransport)? = locked {
            let oldTransport = transport
            activeGeneration = nil
            transport = nil
            setupComplete = false
            isFlushingQueuedMessages = false
            queuedMessages.removeAll(keepingCapacity: false)
            state = .stopped
            return oldTransport
        }
        await oldTransport?.close()
        emit(.stateChanged(.stopped))
    }

    private func connect(_ newTransport: any GeminiLiveTransport, generation: UInt64) async throws {
        try await newTransport.connect { [weak self] event in
            self?.receive(event, generation: generation)
        }
        guard isCurrent(generation) else { return }
        let setup = makeSetupMessage()
        do {
            try await newTransport.send(setup)
        } catch {
            let mapped = Self.mapTransportError(error)
            transitionToFailure(mapped, generation: generation, transportToClose: newTransport)
            throw mapped
        }
    }

    private func receive(_ event: GeminiTransportEvent, generation: UInt64) {
        guard isCurrent(generation) else { return }
        switch event {
        case .message(let message):
            handleMessage(message, generation: generation)
        case .failed(let failure):
            transitionToFailure(Self.mapTransportError(failure), generation: generation, transportToClose: transportFor(generation))
        case .closed(let code, _):
            guard code != 1000 else { return }
            transitionToFailure(.transientNetwork, generation: generation, transportToClose: transportFor(generation))
        }
    }

    private func handleMessage(_ data: Data, generation: UInt64) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            transitionToFailure(.protocolViolation, generation: generation, transportToClose: transportFor(generation))
            return
        }
        if let errorObject = object["error"] as? [String: Any] {
            transitionToFailure(Self.classifyServerError(errorObject), generation: generation, transportToClose: transportFor(generation))
            return
        }

        if object["setupComplete"] != nil {
            completeSetup(generation: generation)
        }
        if let update = object["sessionResumptionUpdate"] as? [String: Any] {
            handleResumptionUpdate(update, generation: generation)
        }
        if let goAway = object["goAway"] as? [String: Any], let timeLeft = Self.parseTimeLeft(goAway["timeLeft"]) {
            emit(.reconnectSuggested(timeLeft: timeLeft))
            onReconnectSuggested?(timeLeft)
        }
        guard let content = object["serverContent"] as? [String: Any],
              let turn = content["modelTurn"] as? [String: Any],
              let parts = turn["parts"] as? [[String: Any]] else { return }
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any],
                  let encoded = inline["data"] as? String,
                  let bytes = Data(base64Encoded: encoded) else { continue }
            let mimeType = inline["mimeType"] as? String
            guard Self.audioRate(from: mimeType) == 24_000, bytes.count.isMultiple(of: 2) else {
                transitionToFailure(.protocolViolation, generation: generation, transportToClose: transportFor(generation))
                return
            }
            let raw = Array(bytes)
            var samples = [Int16]()
            samples.reserveCapacity(raw.count / 2)
            for index in stride(from: 0, to: raw.count, by: 2) {
                let bits = UInt16(raw[index]) | (UInt16(raw[index + 1]) << 8)
                samples.append(Int16(bitPattern: bits))
            }
            emit(.audio(PCMChunk(sampleRate: 24_000, channels: 1, samples: samples)))
        }
    }

    private func completeSetup(generation: UInt64) {
        let destination: (any GeminiLiveTransport)?
        lock.lock()
        guard activeGeneration == generation, !setupComplete else {
            lock.unlock()
            return
        }
        setupComplete = true
        isFlushingQueuedMessages = true
        state = .translating
        destination = transport
        lock.unlock()
        emit(.setupCompleted)
        emit(.stateChanged(.translating))
        guard let destination else { return }
        Task {
            do {
                while true {
                    guard self.isCurrent(generation) else { return }
                    let message: Data? = self.locked {
                        if self.activeGeneration == generation, !self.queuedMessages.isEmpty {
                            return self.queuedMessages.removeFirst()
                        }
                        self.isFlushingQueuedMessages = false
                        return nil
                    }
                    guard let message else { return }
                    try await destination.send(message)
                }
            } catch {
                self.transitionToFailure(Self.mapTransportError(error), generation: generation, transportToClose: destination)
            }
        }
    }

    private func handleResumptionUpdate(_ update: [String: Any], generation: UInt64) {
        guard isCurrent(generation) else { return }
        let resumable = update["resumable"] as? Bool ?? true
        let token = (update["newHandle"] as? String) ?? (update["resumptionToken"] as? String)
        lock.lock()
        guard activeGeneration == generation else {
            lock.unlock()
            return
        }
        if resumable, let token, !token.isEmpty {
            resumptionToken = token
        } else if !resumable {
            resumptionToken = nil
        }
        lock.unlock()
        emit(.sessionResumptionUpdated)
    }

    private func transitionToFailure(
        _ error: GeminiLiveSessionError,
        generation: UInt64?,
        transportToClose: (any GeminiLiveTransport)?
    ) {
        lock.lock()
        if let generation, activeGeneration != generation {
            lock.unlock()
            return
        }
        guard state != .failed, state != .stopped else {
            lock.unlock()
            return
        }
        activeGeneration = nil
        transport = nil
        setupComplete = false
        isFlushingQueuedMessages = false
        queuedMessages.removeAll(keepingCapacity: false)
        state = .failed
        lock.unlock()
        emit(.error(error))
        // A transient network error is the reconnect decision signal. Emitting
        // a second generic failed state would race that reconnect with terminal
        // pipeline teardown.
        if error.isTerminal {
            emit(.stateChanged(.failed))
        }
        Task { await transportToClose?.close() }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeGeneration == generation
    }

    private func transportFor(_ generation: UInt64) -> (any GeminiLiveTransport)? {
        lock.lock(); defer { lock.unlock() }
        return activeGeneration == generation ? transport : nil
    }

    private func emit(_ event: GeminiLiveSessionEvent) { onEvent(event) }

    private func makeSetupMessage() -> Data {
        lock.lock(); let token = resumptionToken; lock.unlock()
        var setup: [String: Any] = [
            "model": "models/\(Self.model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "translationConfig": [
                    "targetLanguageCode": targetLanguageCode,
                    "echoTargetLanguage": false
                ]
            ],
            "outputAudioTranscription": [:]
        ]
        if let token, !token.isEmpty { setup["sessionResumption"] = ["handle": token] }
        return (try? JSONSerialization.data(withJSONObject: ["setup": setup], options: [.sortedKeys])) ?? Data("{\"setup\":{}}".utf8)
    }

    private static func makeAudioMessage(for chunk: PCMChunk) throws -> Data {
        var bytes = Data(capacity: chunk.samples.count * 2)
        for sample in chunk.samples {
            let bits = UInt16(bitPattern: sample)
            bytes.append(UInt8(bits & 0xff))
            bytes.append(UInt8((bits >> 8) & 0xff))
        }
        let payload: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": bytes.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ]
        guard let result = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw GeminiLiveSessionError.protocolViolation
        }
        return result
    }

    private static func mapTransportError(_ error: Error) -> GeminiLiveSessionError {
        if let failure = error as? GeminiTransportFailure {
            switch failure {
            case .notConnected, .network: return .transientNetwork
            case .cancelled: return .stopped
            }
        }
        if error is CancellationError { return .stopped }
        return .transientNetwork
    }

    private static func classifyServerError(_ error: [String: Any]) -> GeminiLiveSessionError {
        let status = (error["status"] as? String ?? "").lowercased()
        let message = (error["message"] as? String ?? "").lowercased()
        let code = (error["code"] as? NSNumber)?.intValue
        let text = "\(status) \(message)"
        if text.contains("billing") || code == 402 { return .billing }
        if text.contains("quota") || text.contains("resource_exhausted") || code == 429 { return .quota }
        if text.contains("unauthenticated") || text.contains("permission_denied") || text.contains("api key") || code == 401 || code == 403 {
            return .authentication
        }
        if text.contains("invalid_argument") || code == 400 { return .invalidRequest }
        return .unknown
    }

    private static func audioRate(from mimeType: String?) -> Int? {
        guard let mimeType else { return nil }
        for part in mimeType.split(separator: ";") {
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if item.lowercased().hasPrefix("rate=") { return Int(item.dropFirst(5)) }
        }
        return nil
    }

    private static func parseTimeLeft(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("s") { return Double(trimmed.dropLast()) }
        return Double(trimmed)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public typealias GeminiLiveSession = GeminiLiveTranslationSession
public typealias GeminiSessionEvent = GeminiLiveSessionEvent
public typealias GeminiSessionError = GeminiLiveSessionError
