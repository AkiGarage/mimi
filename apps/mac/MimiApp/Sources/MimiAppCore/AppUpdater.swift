import CryptoKit
import Foundation

public final class AppUpdater {
    private let installedAppURL: URL
    private let stateDirectoryURL: URL
    private let policy: AppUpdatePolicy
    private let fileManager: FileManager
    private let phaseObserver: (AppUpdatePhase) throws -> Void

    public init(
        installedAppURL: URL,
        stateDirectoryURL: URL,
        policy: AppUpdatePolicy
    ) {
        self.installedAppURL = installedAppURL
        self.stateDirectoryURL = stateDirectoryURL
        self.policy = policy
        fileManager = .default
        phaseObserver = { _ in }
    }

    init(
        installedAppURL: URL,
        stateDirectoryURL: URL,
        policy: AppUpdatePolicy,
        phaseObserver: @escaping (AppUpdatePhase) throws -> Void
    ) {
        self.installedAppURL = installedAppURL
        self.stateDirectoryURL = stateDirectoryURL
        self.policy = policy
        fileManager = .default
        self.phaseObserver = phaseObserver
    }

    public func apply(manifestData: Data) throws -> AppUpdateResult {
        try validateStateDirectory()
        _ = try recoverInterruptedUpdate()
        let candidate = try validatedCandidate(from: manifestData)
        try prepareStagedApp(from: candidate.artifactURL, expectedDigest: candidate.manifest.artifactSHA256)
        let journal = UpdateJournal(
            phase: .prepared,
            previousIdentity: candidate.installedIdentity,
            previousDigest: candidate.installedDigest
        )
        try beginTransaction(journal)
        var installedWasBackedUp = false
        do {
            try backupInstalledApp()
            installedWasBackedUp = true
            try installStagedApp(journal: journal)
            let installedDigest = try AppBundleDigest.sha256(at: installedAppURL)
            guard installedDigest == candidate.manifest.artifactSHA256 else {
                throw AppUpdateError.checksumMismatch
            }
            try markTransactionCommitted()
            try phaseObserver(.afterCommit)
            try? removeIfPresent(backupURL)
            return AppUpdateResult(
                previousVersion: candidate.installedIdentity.version,
                installedVersion: candidate.artifactIdentity.version
            )
        } catch let interruption as AppUpdateInterruption {
            throw interruption
        } catch {
            let updateError = error as? AppUpdateError ?? .transactionFailed
            if installedWasBackedUp {
                try rollbackTransaction(journal: journal)
            } else {
                try abandonPreparedTransaction()
            }
            throw updateError
        }
    }

    public func recoverInterruptedUpdate() throws -> AppUpdateRecoveryResult {
        try validateStateDirectory()
        guard fileManager.fileExists(atPath: journalURL.path) else {
            if fileManager.fileExists(atPath: backupURL.path),
               fileManager.fileExists(atPath: installedAppURL.path) {
                try removeIfPresent(backupURL)
                try removeIfPresent(stagedURL)
                return .committedUpdateRetained
            }
            if fileManager.fileExists(atPath: backupURL.path) { throw AppUpdateError.recoveryFailed }
            try removeIfPresent(stagedURL)
            return .nothingToRecover
        }
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(UpdateJournal.self, from: data) else {
            throw AppUpdateError.recoveryFailed
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            try rollbackTransaction(journal: journal)
            return .rolledBack
        }
        guard fileManager.fileExists(atPath: installedAppURL.path),
              try installedAppMatchesPreviousVersion(journal) else {
            throw AppUpdateError.recoveryFailed
        }
        try removeIfPresent(stagedURL)
        try removeIfPresent(journalURL)
        return .rolledBack
    }

    private func validatedCandidate(from data: Data) throws -> UpdateCandidate {
        guard let manifest = try? JSONDecoder().decode(AppUpdateManifest.self, from: data) else {
            throw AppUpdateError.invalidManifest
        }
        guard manifest.source == policy.expectedSource else { throw AppUpdateError.wrongSource }
        let artifactURL = try resolveArtifactURL(manifest.artifactRelativePath)
        let digest = try AppBundleDigest.sha256(at: artifactURL)
        guard digest == manifest.artifactSHA256 else { throw AppUpdateError.checksumMismatch }
        try verifySignature(manifest)
        let artifactIdentity = try AppBundleIdentity.read(from: artifactURL)
        guard artifactIdentity == AppBundleIdentity(version: manifest.version, build: manifest.build) else {
            throw AppUpdateError.artifactIdentityMismatch
        }
        let installedIdentity = try AppBundleIdentity.read(from: installedAppURL)
        try requireNewer(artifactIdentity, than: installedIdentity)
        let installedDigest = try AppBundleDigest.sha256(at: installedAppURL)
        return UpdateCandidate(
            manifest: manifest,
            artifactURL: artifactURL,
            installedIdentity: installedIdentity,
            installedDigest: installedDigest,
            artifactIdentity: artifactIdentity
        )
    }

    private func resolveArtifactURL(_ relativePath: String) throws -> URL {
        let components = NSString(string: relativePath).pathComponents
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !components.contains(".."),
              !components.contains(".") else {
            throw AppUpdateError.invalidArtifactPath
        }
        let root = policy.feedRootURL.resolvingSymlinksInPath().standardizedFileURL
        let lexicalURL = policy.feedRootURL.appendingPathComponent(relativePath).standardizedFileURL
        let artifactURL = lexicalURL.resolvingSymlinksInPath().standardizedFileURL
        guard artifactURL.path.hasPrefix(root.path + "/") else {
            throw AppUpdateError.invalidArtifactPath
        }
        let values = try? lexicalURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw AppUpdateError.invalidArtifactPath }
        return artifactURL
    }

    private func verifySignature(_ manifest: AppUpdateManifest) throws {
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: policy.trustedPublicKey)
        } catch {
            throw AppUpdateError.invalidPublicKey
        }
        guard publicKey.isValidSignature(manifest.signature, for: manifest.signingPayload) else {
            throw AppUpdateError.invalidSignature
        }
    }

    private func requireNewer(_ candidate: AppBundleIdentity, than installed: AppBundleIdentity) throws {
        guard let candidateVersion = ReleaseVersion(candidate.version),
              let installedVersion = ReleaseVersion(installed.version),
              let candidateBuild = Int(candidate.build),
              let installedBuild = Int(installed.build),
              candidateVersion > installedVersion,
              candidateBuild > installedBuild else {
            throw AppUpdateError.versionNotNewer
        }
    }

    private func validateStateDirectory() throws {
        let appParent = installedAppURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let stateParent = stateDirectoryURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard appParent == stateParent else { throw AppUpdateError.invalidStateDirectory }
        if fileManager.fileExists(atPath: stateDirectoryURL.path) {
            let values = try? stateDirectoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { throw AppUpdateError.invalidStateDirectory }
        }
    }

    private func prepareStagedApp(from source: URL, expectedDigest: String) throws {
        try fileManager.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: backupURL.path) { throw AppUpdateError.recoveryFailed }
        try removeIfPresent(stagedURL)
        do {
            try fileManager.copyItem(at: source, to: stagedURL)
            let stagedDigest = try AppBundleDigest.sha256(at: stagedURL)
            guard stagedDigest == expectedDigest else { throw AppUpdateError.checksumMismatch }
        } catch let error as AppUpdateError {
            try? removeIfPresent(stagedURL)
            throw error
        } catch {
            try? removeIfPresent(stagedURL)
            throw AppUpdateError.transactionFailed
        }
    }

    private func beginTransaction(_ journal: UpdateJournal) throws {
        do {
            try writeJournal(journal)
        } catch {
            try? removeIfPresent(stagedURL)
            throw error
        }
    }

    private func backupInstalledApp() throws {
        guard !fileManager.fileExists(atPath: backupURL.path) else {
            throw AppUpdateError.recoveryFailed
        }
        try fileManager.moveItem(at: installedAppURL, to: backupURL)
    }

    private func installStagedApp(journal: UpdateJournal) throws {
        try writeJournal(journal.withPhase(.backedUp))
        try phaseObserver(.afterBackup)
        try fileManager.moveItem(at: stagedURL, to: installedAppURL)
        try writeJournal(journal.withPhase(.installed))
        try phaseObserver(.afterInstall)
    }

    private func rollbackTransaction(journal: UpdateJournal) throws {
        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try validateBackup(journal)
                if fileManager.fileExists(atPath: installedAppURL.path) {
                    _ = try fileManager.replaceItemAt(installedAppURL, withItemAt: backupURL)
                } else {
                    try fileManager.moveItem(at: backupURL, to: installedAppURL)
                }
                try phaseObserver(.afterRollback)
            }
            try removeIfPresent(stagedURL)
            try removeIfPresent(journalURL)
        } catch let interruption as AppUpdateInterruption {
            throw interruption
        } catch {
            throw AppUpdateError.recoveryFailed
        }
    }

    private func installedAppMatchesPreviousVersion(_ journal: UpdateJournal) throws -> Bool {
        do {
            let identity = try AppBundleIdentity.read(from: installedAppURL)
            let digest = try AppBundleDigest.sha256(at: installedAppURL)
            return identity == journal.previousIdentity && digest == journal.previousDigest
        } catch {
            return false
        }
    }

    private func validateBackup(_ journal: UpdateJournal) throws {
        let identity = try AppBundleIdentity.read(from: backupURL)
        let digest = try AppBundleDigest.sha256(at: backupURL)
        guard identity == journal.previousIdentity,
              digest == journal.previousDigest else {
            throw AppUpdateError.recoveryFailed
        }
    }

    private func abandonPreparedTransaction() throws {
        try removeIfPresent(stagedURL)
        try removeIfPresent(journalURL)
        if fileManager.fileExists(atPath: backupURL.path) { throw AppUpdateError.recoveryFailed }
    }

    private func markTransactionCommitted() throws {
        try removeIfPresent(journalURL)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func writeJournal(_ journal: UpdateJournal) throws {
        do {
            let data = try JSONEncoder().encode(journal)
            try data.write(to: journalURL, options: .atomic)
        } catch {
            throw AppUpdateError.transactionFailed
        }
    }

    private var journalURL: URL { stateDirectoryURL.appendingPathComponent("transaction.json") }
    private var backupURL: URL { stateDirectoryURL.appendingPathComponent("backup-Mimi.app") }
    private var stagedURL: URL { stateDirectoryURL.appendingPathComponent("staged-Mimi.app") }
}

private struct UpdateCandidate {
    let manifest: AppUpdateManifest
    let artifactURL: URL
    let installedIdentity: AppBundleIdentity
    let installedDigest: String
    let artifactIdentity: AppBundleIdentity
}

private struct UpdateJournal: Codable {
    enum Phase: String, Codable {
        case prepared
        case backedUp
        case installed
    }

    let phase: Phase
    let previousIdentity: AppBundleIdentity
    let previousDigest: String

    func withPhase(_ phase: Phase) -> UpdateJournal {
        UpdateJournal(phase: phase, previousIdentity: previousIdentity, previousDigest: previousDigest)
    }
}
