import Foundation

public enum MimiProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case gemini
    case openai

    public var id: String { rawValue }

    /// Converts values from older or newer local-server versions without
    /// allowing a removed/unknown provider into the client selection state.
    public static func fromServerValue(_ value: String?) -> MimiProvider? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gemini":
            return .gemini
        case "openai":
            return .openai
        case "xai", "grok":
            return .gemini
        default:
            return nil
        }
    }
}

public struct ProviderSettingsResponse: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let preferredProvider: MimiProvider?

    public init(ok: Bool, preferredProvider: MimiProvider?) {
        self.ok = ok
        self.preferredProvider = preferredProvider
    }

    private enum CodingKeys: String, CodingKey {
        case ok
        case preferredProvider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        preferredProvider = MimiProvider.fromServerValue(
            try? container.decode(String.self, forKey: .preferredProvider)
        )
    }
}

public struct ServerStatus: Decodable, Equatable {
    public let ok: Bool
    public let service: String
    public let mode: String
    public let activeSessions: Int
    public let realModeReady: Bool
    public let allowedExtensionOriginConfigured: Bool
    public let allowedExtensionId: String
    public let extensionConnection: ExtensionConnectionStatus?
    public let setupProgress: SetupProgressStatus?
    public let diagnostics: DiagnosticsStatus?
    public let billing: BillingStatus?
    /// Older local-server versions omit this field; Mimi keeps its current/default provider in that case.
    public let preferredProvider: MimiProvider?

    private enum CodingKeys: String, CodingKey {
        case ok
        case service
        case mode
        case activeSessions
        case realModeReady
        case allowedExtensionOriginConfigured
        case allowedExtensionId
        case extensionConnection
        case setupProgress
        case diagnostics
        case billing
        case preferredProvider
    }

    public struct ExtensionConnectionStatus: Decodable, Equatable {
        public let verified: Bool
        public let lastSeenAt: String?
        public let isOnToolbar: Bool?
        public let installedAt: String?
        public let toolbarChangedAt: String?
        public let popupOpenedAt: String?
    }

    public struct DiagnosticsStatus: Decodable, Equatable {
        public let enabled: Bool
    }

    public struct SetupProgressStatus: Decodable, Equatable {
        public let listeningStarted: Bool
        public let listeningStartedAt: String?
    }

    public struct BillingStatus: Decodable, Equatable {
        public let monthlyLimitEnabled: Bool?
        public let limitSeconds: Double
        public let usedSeconds: Double
        public let remainingSeconds: Double?

        public var limitMinutes: Double {
            limitSeconds / 60
        }

        public var usedMinutes: Double {
            usedSeconds / 60
        }

        public var remainingMinutes: Double {
            (remainingSeconds ?? 0) / 60
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        service = try container.decode(String.self, forKey: .service)
        mode = try container.decode(String.self, forKey: .mode)
        activeSessions = try container.decode(Int.self, forKey: .activeSessions)
        realModeReady = try container.decode(Bool.self, forKey: .realModeReady)
        allowedExtensionOriginConfigured = try container.decode(
            Bool.self,
            forKey: .allowedExtensionOriginConfigured
        )
        allowedExtensionId = try container.decode(String.self, forKey: .allowedExtensionId)
        extensionConnection = try container.decodeIfPresent(
            ExtensionConnectionStatus.self,
            forKey: .extensionConnection
        )
        setupProgress = try container.decodeIfPresent(SetupProgressStatus.self, forKey: .setupProgress)
        diagnostics = try container.decodeIfPresent(DiagnosticsStatus.self, forKey: .diagnostics)
        billing = try container.decodeIfPresent(BillingStatus.self, forKey: .billing)

        // Keep the write-side enum closed, but allow newer local servers to add
        // a provider without making the whole /status payload unreadable.
        preferredProvider = MimiProvider.fromServerValue(
            try? container.decode(String.self, forKey: .preferredProvider)
        )
    }

    public var isMimiServer: Bool {
        ok && service == "jp-dub-local-server"
    }

    public var isServerPreparedForChrome: Bool {
        isMimiServer && mode == "real" && realModeReady && allowedExtensionOriginConfigured
    }

    public var isReadyForChrome: Bool {
        isServerPreparedForChrome
            && extensionConnection?.verified == true
            && extensionConnection?.isOnToolbar == true
            && extensionConnection?.installedAt != nil
            && extensionConnection?.toolbarChangedAt != nil
            && extensionConnection?.popupOpenedAt != nil
    }
}

public struct ServerStatusClient {
    public let statusURL: URL
    private let fetch: () async throws -> ServerStatus
    private let writeProvider: (MimiProvider) async throws -> ProviderSettingsResponse

    public init(statusURL: URL = URL(string: "http://127.0.0.1:8787/status")!, session: URLSession = .shared) {
        self.statusURL = statusURL
        self.fetch = {
            let (data, response) = try await session.data(from: statusURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(ServerStatus.self, from: data)
        }
        let providerURL = statusURL
            .deletingLastPathComponent()
            .appendingPathComponent("settings")
            .appendingPathComponent("provider")
        self.writeProvider = {
            provider in
            var request = URLRequest(url: providerURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["provider": provider.rawValue])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(ProviderSettingsResponse.self, from: data)
        }
    }

    public init(
        fetchStatus: @escaping () async throws -> ServerStatus,
        writeProvider: @escaping (MimiProvider) async throws -> ProviderSettingsResponse = { _ in
            throw ServerStatusError.providerWriteUnavailable
        }
    ) {
        self.statusURL = URL(string: "http://127.0.0.1:8787/status")!
        self.fetch = fetchStatus
        self.writeProvider = writeProvider
    }

    public init(
        fetchStatus: @escaping () async throws -> ServerStatus,
        setProvider: @escaping (MimiProvider) async throws -> ProviderSettingsResponse
    ) {
        self.init(fetchStatus: fetchStatus, writeProvider: setProvider)
    }

    public func fetchStatus() async throws -> ServerStatus {
        try await fetch()
    }

    @discardableResult
    public func setPreferredProvider(_ provider: MimiProvider) async throws -> MimiProvider {
        let response = try await writeProvider(provider)
        guard response.ok else {
            throw ServerStatusError.providerWriteFailed
        }
        return response.preferredProvider ?? provider
    }

    public func waitUntilReady(
        maxAttempts: Int = 28,
        retryDelayNanoseconds: UInt64 = 250_000_000,
        onStatus: ((ServerStatus) async -> Void)? = nil
    ) async throws -> ServerStatus {
        var lastError: Error?
        for attempt in 0..<max(1, maxAttempts) {
            do {
                let status = try await fetchStatus()
                if let onStatus {
                    await onStatus(status)
                }
                if status.isReadyForChrome {
                    return status
                }
                lastError = ServerStatusError.notReady
            } catch {
                lastError = error
            }
            if attempt + 1 < maxAttempts, retryDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
        throw lastError ?? ServerStatusError.notReady
    }

    public func waitUntilServerPrepared(
        maxAttempts: Int = 28,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) async throws -> ServerStatus {
        try await waitUntil(maxAttempts: maxAttempts, retryDelayNanoseconds: retryDelayNanoseconds) {
            $0.isServerPreparedForChrome
        }
    }

    private func waitUntil(
        maxAttempts: Int,
        retryDelayNanoseconds: UInt64,
        predicate: (ServerStatus) -> Bool
    ) async throws -> ServerStatus {
        var lastError: Error?
        for attempt in 0..<max(1, maxAttempts) {
            do {
                let status = try await fetchStatus()
                if predicate(status) {
                    return status
                }
                lastError = ServerStatusError.notReady
            } catch {
                lastError = error
            }
            if attempt + 1 < maxAttempts, retryDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
        throw lastError ?? ServerStatusError.notReady
    }
}

public enum ServerStatusError: LocalizedError {
    case notReady
    case providerWriteUnavailable
    case providerWriteFailed

    public var errorDescription: String? {
        switch self {
        case .notReady:
            "Mimi local server did not become ready for Chrome."
        case .providerWriteUnavailable:
            "Mimi provider settings are unavailable in this test client."
        case .providerWriteFailed:
            "Mimi could not save the translation provider."
        }
    }
}
