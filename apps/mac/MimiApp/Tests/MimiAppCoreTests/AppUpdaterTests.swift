import CryptoKit
import Foundation
import Testing
@testable import MimiAppCore

@Test func signedUpdateSucceedsAndRepeatsDeterministically() throws {
    for iteration in 0..<2 {
        let fixture = try UpdateFixture(name: "happy-\(iteration)")
        defer { fixture.remove() }
        let manifest = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")

        let result = try fixture.updater().apply(manifestData: manifest)

        #expect(result == AppUpdateResult(previousVersion: "0.1.0", installedVersion: "0.1.1"))
        #expect(try fixture.installedIdentity() == AppBundleIdentity(version: "0.1.1", build: "2"))
        #expect(try fixture.installedPayload() == "new")
        #expect(!fixture.transactionArtifactsExist())

        #expect(throws: AppUpdateError.versionNotNewer) {
            try fixture.updater().apply(manifestData: manifest)
        }
        #expect(try fixture.installedPayload() == "new")
        #expect(!fixture.transactionArtifactsExist())
    }
}

@Test func updateRejectsInvalidSignatureWithoutChangingInstalledApp() throws {
    let fixture = try UpdateFixture(name: "invalid-signature")
    defer { fixture.remove() }
    var manifest = try fixture.decodeManifest(
        fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
    )
    manifest.signature = Data(repeating: 0, count: 64)

    #expect(throws: AppUpdateError.invalidSignature) {
        try fixture.updater().apply(manifestData: fixture.encodeManifest(manifest))
    }
    try fixture.expectOriginalApp()
}

@Test func updateRejectsWrongSourceWithoutChangingInstalledApp() throws {
    let fixture = try UpdateFixture(name: "wrong-source")
    defer { fixture.remove() }
    let manifest = try fixture.makeSignedUpdate(
        version: "0.1.1",
        build: "2",
        payload: "new",
        source: "unexpected-source"
    )

    #expect(throws: AppUpdateError.wrongSource) {
        try fixture.updater().apply(manifestData: manifest)
    }
    try fixture.expectOriginalApp()
}

@Test func updateRejectsWrongBuildAndStaleVersion() throws {
    let fixture = try UpdateFixture(name: "wrong-build")
    defer { fixture.remove() }
    let mismatched = try fixture.makeSignedUpdate(
        version: "0.1.1",
        build: "3",
        payload: "new",
        artifactVersion: "0.1.1",
        artifactBuild: "2"
    )
    #expect(throws: AppUpdateError.artifactIdentityMismatch) {
        try fixture.updater().apply(manifestData: mismatched)
    }
    try fixture.expectOriginalApp()

    let stale = try fixture.makeSignedUpdate(version: "0.1.0", build: "1", payload: "stale")
    #expect(throws: AppUpdateError.versionNotNewer) {
        try fixture.updater().apply(manifestData: stale)
    }
    try fixture.expectOriginalApp()
}

@Test func updateRejectsTraversalAbsoluteAndSymlinkArtifactPaths() throws {
    let fixture = try UpdateFixture(name: "unsafe-paths")
    defer { fixture.remove() }
    let validData = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
    let valid = try fixture.decodeManifest(validData)

    for unsafePath in ["../Mimi.app", "/tmp/Mimi.app", "nested/../Mimi.app"] {
        let manifest = try fixture.resign(valid, artifactRelativePath: unsafePath)
        #expect(throws: AppUpdateError.invalidArtifactPath) {
            try fixture.updater().apply(manifestData: manifest)
        }
        try fixture.expectOriginalApp()
    }

    let link = fixture.feedRoot.appendingPathComponent("linked-Mimi.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.latestArtifactApp)
    let linked = try fixture.resign(valid, artifactRelativePath: link.lastPathComponent)
    #expect(throws: AppUpdateError.invalidArtifactPath) {
        try fixture.updater().apply(manifestData: linked)
    }
    try fixture.expectOriginalApp()
}

@Test func corruptedArtifactLeavesCurrentVersionUntouched() throws {
    let fixture = try UpdateFixture(name: "corrupted")
    defer { fixture.remove() }
    let data = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
    try "tampered".write(to: fixture.latestArtifactPayload, atomically: true, encoding: .utf8)

    #expect(throws: AppUpdateError.checksumMismatch) {
        try fixture.updater().apply(manifestData: data)
    }
    try fixture.expectOriginalApp()
    #expect(!fixture.transactionArtifactsExist())
}

@Test func interruptedUpdateRecoversOriginalVersionDeterministically() throws {
    for iteration in 0..<2 {
        let fixture = try UpdateFixture(name: "interrupted-\(iteration)")
        defer { fixture.remove() }
        let manifest = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
        let interrupted = fixture.updater { phase in
            if phase == .afterBackup { throw AppUpdateInterruption.simulatedCrash }
        }

        #expect(throws: AppUpdateInterruption.simulatedCrash) {
            try interrupted.apply(manifestData: manifest)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installedApp.path))

        #expect(try fixture.updater().recoverInterruptedUpdate() == .rolledBack)
        try fixture.expectOriginalApp()
        #expect(!fixture.transactionArtifactsExist())
    }
}

@Test func failedInstalledBundleRollsBackDeterministically() throws {
    for iteration in 0..<2 {
        let fixture = try UpdateFixture(name: "rollback-\(iteration)")
        defer { fixture.remove() }
        let manifest = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
        let failing = fixture.updater { phase in
            if phase == .afterInstall {
                try "corrupt".write(to: fixture.installedPayloadURL, atomically: true, encoding: .utf8)
            }
        }

        #expect(throws: AppUpdateError.checksumMismatch) {
            try failing.apply(manifestData: manifest)
        }
        try fixture.expectOriginalApp()
        #expect(!fixture.transactionArtifactsExist())
    }
}

@Test func corruptedBackupIsNeverInstalledDuringRecovery() throws {
    let fixture = try UpdateFixture(name: "corrupted-backup")
    defer { fixture.remove() }
    let manifest = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
    let interrupted = fixture.updater { phase in
        if phase == .afterBackup { throw AppUpdateInterruption.simulatedCrash }
    }
    #expect(throws: AppUpdateInterruption.simulatedCrash) {
        try interrupted.apply(manifestData: manifest)
    }
    try "corrupt-backup".write(to: fixture.backupPayloadURL, atomically: true, encoding: .utf8)

    #expect(throws: AppUpdateError.recoveryFailed) {
        try fixture.updater().recoverInterruptedUpdate()
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.installedApp.path))
    #expect(FileManager.default.fileExists(atPath: fixture.backupApp.path))
    #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))
}

@Test func interruptionAfterCommitRetainsVerifiedNewVersion() throws {
    let fixture = try UpdateFixture(name: "committed-interruption")
    defer { fixture.remove() }
    let manifest = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
    let interrupted = fixture.updater { phase in
        if phase == .afterCommit { throw AppUpdateInterruption.simulatedCrash }
    }

    #expect(throws: AppUpdateInterruption.simulatedCrash) {
        try interrupted.apply(manifestData: manifest)
    }
    #expect(try fixture.updater().recoverInterruptedUpdate() == .committedUpdateRetained)
    #expect(try fixture.installedIdentity() == AppBundleIdentity(version: "0.1.1", build: "2"))
    #expect(try fixture.installedPayload() == "new")
    #expect(!fixture.transactionArtifactsExist())
}

@Test func interruptionAfterAtomicRollbackReconcilesPreviousVersion() throws {
    let fixture = try UpdateFixture(name: "rollback-interruption")
    defer { fixture.remove() }
    let manifest = try fixture.makeSignedUpdate(version: "0.1.1", build: "2", payload: "new")
    let interrupted = fixture.updater { phase in
        if phase == .afterInstall {
            try "corrupt".write(to: fixture.installedPayloadURL, atomically: true, encoding: .utf8)
        }
        if phase == .afterRollback { throw AppUpdateInterruption.simulatedCrash }
    }

    #expect(throws: AppUpdateInterruption.simulatedCrash) {
        try interrupted.apply(manifestData: manifest)
    }
    try fixture.expectOriginalApp()
    #expect(FileManager.default.fileExists(atPath: fixture.journalURL.path))

    #expect(try fixture.updater().recoverInterruptedUpdate() == .rolledBack)
    try fixture.expectOriginalApp()
    #expect(!fixture.transactionArtifactsExist())
}

private final class UpdateFixture {
    static let source = "mimi-isolated-test-feed"

    let root: URL
    let feedRoot: URL
    let installedApp: URL
    let stateDirectory: URL
    let signer = Curve25519.Signing.PrivateKey()
    private(set) var latestArtifactPayload: URL

    var latestArtifactApp: URL {
        latestArtifactPayload
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiAppUpdaterTests-\(name)-\(UUID().uuidString)")
        feedRoot = root.appendingPathComponent("feed", isDirectory: true)
        installedApp = root.appendingPathComponent("Applications/Mimi.app", isDirectory: true)
        stateDirectory = root.appendingPathComponent("Applications/.MimiUpdate", isDirectory: true)
        latestArtifactPayload = feedRoot
        try FileManager.default.createDirectory(at: feedRoot, withIntermediateDirectories: true)
        try Self.writeApp(at: installedApp, version: "0.1.0", build: "1", payload: "old")
    }

    var installedPayloadURL: URL {
        installedApp.appendingPathComponent("Contents/Resources/payload.txt")
    }

    var backupApp: URL {
        stateDirectory.appendingPathComponent("backup-Mimi.app")
    }

    var backupPayloadURL: URL {
        backupApp.appendingPathComponent("Contents/Resources/payload.txt")
    }

    var journalURL: URL {
        stateDirectory.appendingPathComponent("transaction.json")
    }

    func updater(observer: @escaping (AppUpdatePhase) throws -> Void = { _ in }) -> AppUpdater {
        AppUpdater(
            installedAppURL: installedApp,
            stateDirectoryURL: stateDirectory,
            policy: AppUpdatePolicy(
                expectedSource: Self.source,
                feedRootURL: feedRoot,
                trustedPublicKey: signer.publicKey.rawRepresentation
            ),
            phaseObserver: observer
        )
    }

    func makeSignedUpdate(
        version: String,
        build: String,
        payload: String,
        source: String = source,
        artifactVersion: String? = nil,
        artifactBuild: String? = nil
    ) throws -> Data {
        let relativePath = "Mimi-\(UUID().uuidString).app"
        let artifact = feedRoot.appendingPathComponent(relativePath, isDirectory: true)
        try Self.writeApp(
            at: artifact,
            version: artifactVersion ?? version,
            build: artifactBuild ?? build,
            payload: payload
        )
        latestArtifactPayload = artifact.appendingPathComponent("Contents/Resources/payload.txt")
        let digest = try AppBundleDigest.sha256(at: artifact)
        var manifest = AppUpdateManifest(
            source: source,
            version: version,
            build: build,
            artifactRelativePath: relativePath,
            artifactSHA256: digest,
            signature: Data()
        )
        manifest.signature = try signer.signature(for: manifest.signingPayload)
        return encodeManifest(manifest)
    }

    func installedIdentity() throws -> AppBundleIdentity {
        try AppBundleIdentity.read(from: installedApp)
    }

    func installedPayload() throws -> String {
        try String(contentsOf: installedPayloadURL, encoding: .utf8)
    }

    func expectOriginalApp() throws {
        #expect(try installedIdentity() == AppBundleIdentity(version: "0.1.0", build: "1"))
        #expect(try installedPayload() == "old")
    }

    func transactionArtifactsExist() -> Bool {
        ["transaction.json", "backup-Mimi.app", "staged-Mimi.app"].contains { name in
            FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent(name).path)
        }
    }

    func decodeManifest(_ data: Data) throws -> AppUpdateManifest {
        try JSONDecoder().decode(AppUpdateManifest.self, from: data)
    }

    func encodeManifest(_ manifest: AppUpdateManifest) -> Data {
        try! JSONEncoder().encode(manifest)
    }

    func resign(_ manifest: AppUpdateManifest, artifactRelativePath: String) throws -> Data {
        var changed = AppUpdateManifest(
            source: manifest.source,
            version: manifest.version,
            build: manifest.build,
            artifactRelativePath: artifactRelativePath,
            artifactSHA256: manifest.artifactSHA256,
            signature: Data()
        )
        changed.signature = try signer.signature(for: changed.signingPayload)
        return encodeManifest(changed)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeApp(at url: URL, version: String, build: String, payload: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.akigarage.mimi",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        try payload.write(to: resources.appendingPathComponent("payload.txt"), atomically: true, encoding: .utf8)
    }
}
