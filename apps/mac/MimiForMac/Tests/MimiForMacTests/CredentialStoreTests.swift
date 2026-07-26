import Foundation
import Security
import XCTest
@testable import MimiForMac

final class CredentialStoreTests: XCTestCase {
    func testSaveTrimsAndLoadsWithoutWritingOutsideKeychainAdapter() throws {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(service: "test", account: "default", keychain: keychain)

        try store.save("  test-secret  \n")

        XCTAssertEqual(keychain.savedValue, "test-secret")
        XCTAssertEqual(try store.load(), "test-secret")
        XCTAssertTrue(store.containsCredential())
    }

    func testSaveReplacesDuplicateItem() throws {
        let keychain = FakeKeychain(addStatus: errSecDuplicateItem, stored: "old")
        let store = KeychainCredentialStore(service: "test", account: "default", keychain: keychain)

        try store.save("new")

        XCTAssertEqual(keychain.savedValue, "new")
        XCTAssertEqual(keychain.updateCount, 1)
    }

    func testBlankCredentialIsRejectedBeforeKeychainAccess() {
        let keychain = FakeKeychain()
        let store = KeychainCredentialStore(keychain: keychain)

        XCTAssertThrowsError(try store.save(" \n\t "))
        XCTAssertEqual(keychain.addCount, 0)
    }

    func testRemoveIsIdempotent() throws {
        let keychain = FakeKeychain(stored: "value")
        let store = KeychainCredentialStore(keychain: keychain)

        try store.remove()
        try store.remove()

        XCTAssertFalse(store.containsCredential())
    }
}

private final class FakeKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var addStatus: OSStatus
    private var stored: Data?
    private(set) var addCount = 0
    private(set) var updateCount = 0

    init(addStatus: OSStatus = errSecSuccess, stored: String? = nil) {
        self.addStatus = addStatus
        self.stored = stored.map { Data($0.utf8) }
    }

    var savedValue: String? {
        lock.lock(); defer { lock.unlock() }
        return stored.flatMap { String(data: $0, encoding: .utf8) }
    }

    func add(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        addCount += 1
        let status = addStatus
        addStatus = errSecSuccess
        if status == errSecSuccess { stored = query[kSecValueData as String] as? Data }
        return status
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        updateCount += 1
        stored = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any], result: inout AnyObject?) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard let stored else { return errSecItemNotFound }
        if query[kSecReturnData as String] as? Bool == true {
            result = stored as NSData
        } else {
            result = [:] as NSDictionary
        }
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        guard stored != nil else { return errSecItemNotFound }
        stored = nil
        return errSecSuccess
    }
}
