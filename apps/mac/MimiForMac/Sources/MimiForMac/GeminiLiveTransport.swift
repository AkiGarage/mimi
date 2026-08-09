import Foundation

/// Events delivered by a Gemini WebSocket transport. Message payloads are the
/// wire JSON and are intentionally not decoded by the transport, which keeps
/// fake transports useful in tests.
public enum GeminiTransportEvent: Sendable, Equatable {
    case message(Data)
    case closed(code: Int, reason: String?)
    case failed(GeminiTransportFailure)
}

public enum GeminiTransportFailure: Error, Sendable, Equatable {
    case network
    case notConnected
    case cancelled
}

/// The narrow seam used by `GeminiLiveTranslationSession` and its tests.
/// Implementations must not log or persist the credential passed to them.
public protocol GeminiLiveTransport: AnyObject, Sendable {
    func connect(onEvent: @escaping @Sendable (GeminiTransportEvent) -> Void) async throws
    func send(_ message: Data) async throws
    func close() async
}

/// Direct Gemini Live API WebSocket transport backed only by Foundation.
/// The API credential is carried in a request header so it cannot leak through
/// URL logging, proxy histories, or diagnostics.
public final class URLSessionGeminiLiveTransport: GeminiLiveTransport, @unchecked Sendable {
    public typealias EphemeralTokenProvider = @Sendable (GeminiCredential) async throws -> String
    public static let defaultEndpoint = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained")!
    static let tokenEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1alpha/auth_tokens")!

    private let credential: GeminiCredential
    private let endpoint: URL
    private let tokenProvider: EphemeralTokenProvider
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectionAttempt: UInt64 = 0

    public init(
        credential: GeminiCredential,
        endpoint: URL = URLSessionGeminiLiveTransport.defaultEndpoint
    ) {
        self.credential = credential
        self.endpoint = endpoint
        self.tokenProvider = URLSessionGeminiLiveTransport.fetchEphemeralToken
    }

    init(
        credential: GeminiCredential,
        endpoint: URL = URLSessionGeminiLiveTransport.defaultEndpoint,
        tokenProvider: @escaping EphemeralTokenProvider
    ) {
        self.credential = credential
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
    }

    static func tokenRequest(for credential: GeminiCredential) -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential.opaqueValue, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = Data(#"{"uses":1}"#.utf8)
        return request
    }

    static func webSocketRequest(endpoint: URL, token: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func fetchEphemeralToken(credential: GeminiCredential) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: tokenRequest(for: credential))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["name"] as? String, !token.isEmpty else {
            throw GeminiTransportFailure.network
        }
        return token
    }

    public func connect(onEvent: @escaping @Sendable (GeminiTransportEvent) -> Void) async throws {
        let attempt: UInt64? = locked {
            guard task == nil else { return nil }
            connectionAttempt &+= 1
            return connectionAttempt
        }
        guard let attempt else { return }

        let token: String
        do {
            token = try await tokenProvider(credential)
        } catch is CancellationError {
            throw GeminiTransportFailure.cancelled
        } catch {
            throw GeminiTransportFailure.network
        }
        let request = Self.webSocketRequest(endpoint: endpoint, token: token)
        guard let socket: URLSessionWebSocketTask = locked({
            guard task == nil, connectionAttempt == attempt else { return nil }
            let socket = URLSession.shared.webSocketTask(with: request)
            task = socket
            return socket
        }) else { return }

        socket.resume()
        receiveTask = Task { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    switch message {
                    case .string(let text):
                        onEvent(.message(Data(text.utf8)))
                    case .data(let data):
                        onEvent(.message(data))
                    @unknown default:
                        onEvent(.failed(.network))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    onEvent(.failed(.network))
                    return
                }
            }
            _ = self
        }
    }

    public func send(_ message: Data) async throws {
        let socket = locked { task }
        guard let socket else { throw GeminiTransportFailure.notConnected }
        do {
            try await socket.send(.data(message))
        } catch is CancellationError {
            throw GeminiTransportFailure.cancelled
        } catch {
            throw GeminiTransportFailure.network
        }
    }

    public func close() async {
        let (socket, receiveTask) = locked {
            let values = (task, self.receiveTask)
            connectionAttempt &+= 1
            task = nil
            self.receiveTask = nil
            return values
        }

        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public typealias GeminiLiveWebSocketTransport = URLSessionGeminiLiveTransport
