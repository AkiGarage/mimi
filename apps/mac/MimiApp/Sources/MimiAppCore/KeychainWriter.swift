import Foundation
import Security

public enum KeychainError: LocalizedError, Equatable {
    case emptyPassword
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "APIキーが空です。AI Studioでコピーしたキーを1行で貼り付けてください。"
        case .unexpectedStatus(let status):
            if status == errSecDuplicateItem {
                return "APIキーをKeychainに保存または差し替えできませんでした。Mimi Setupをもう一度開き、新しいキーを貼り付けて再試行してください。"
            }
            return "APIキーをKeychainに保存できませんでした。Mimi Setupをもう一度開き、macOSのKeychainアクセスを許可してから再試行してください。"
        }
    }
}

public protocol KeychainAccessing {
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> OSStatus
}

public struct SystemKeychain: KeychainAccessing {
    public init() {}

    public func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func copyMatching(_ query: [String: Any]) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, nil)
    }
}

public struct KeychainWriter {
    public static let defaultService = "Mimi Gemini API Key"
    public static let defaultAccount = "default"

    public let service: String
    public let account: String
    private let keychain: KeychainAccessing

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        keychain: KeychainAccessing = SystemKeychain()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    public func save(_ password: String) throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError.emptyPassword }
        var query = baseQuery()
        query[kSecValueData as String] = Data(trimmed.utf8)
        let addStatus = keychain.add(query)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = keychain.update(
                baseQuery(),
                attributes: [kSecValueData as String: Data(trimmed.utf8)]
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    public func hasPassword() -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        return keychain.copyMatching(query) == errSecSuccess
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
