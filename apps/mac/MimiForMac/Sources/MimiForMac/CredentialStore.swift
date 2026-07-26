import Foundation
import Security

public enum CredentialStoreError: LocalizedError, Equatable {
    case emptyCredential
    case notFound
    case keychainFailure

    public var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "APIキーが空です。Google AI Studioからコピーした値を入力してください。"
        case .notFound:
            "APIキーがKeychainに保存されていません。"
        case .keychainFailure:
            "APIキーをKeychainで処理できませんでした。macOSの設定を確認して再試行してください。"
        }
    }
}

public protocol KeychainAccessing: Sendable {
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], result: inout AnyObject?) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemKeychain: KeychainAccessing {
    public init() {}

    public func add(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func copyMatching(_ query: [String: Any], result: inout AnyObject?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainCredentialStore: Sendable {
    public static let defaultService = "Mimi for Mac Gemini API Key"
    public static let defaultAccount = "default"

    private let service: String
    private let account: String
    private let keychain: any KeychainAccessing

    public init(
        service: String = Self.defaultService,
        account: String = Self.defaultAccount,
        keychain: any KeychainAccessing = SystemKeychain()
    ) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }

    public func save(_ credential: String) throws {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CredentialStoreError.emptyCredential }

        var query = baseQuery
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = keychain.add(query)
        if status == errSecDuplicateItem {
            let update = keychain.update(
                baseQuery,
                attributes: [
                    kSecValueData as String: Data(value.utf8),
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                ]
            )
            guard update == errSecSuccess else { throw CredentialStoreError.keychainFailure }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychainFailure
        }
    }

    public func load() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = keychain.copyMatching(query, result: &result)
        if status == errSecItemNotFound { throw CredentialStoreError.notFound }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw CredentialStoreError.keychainFailure
        }
        return value
    }

    public func containsCredential() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return keychain.copyMatching(query, result: &result) == errSecSuccess
    }

    public func remove() throws {
        let status = keychain.delete(baseQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
