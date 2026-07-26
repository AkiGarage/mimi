import Foundation

public struct AppUpdateManifest: Codable, Equatable {
    public let source: String
    public let version: String
    public let build: String
    public let artifactRelativePath: String
    public let artifactSHA256: String
    public var signature: Data

    public init(
        source: String,
        version: String,
        build: String,
        artifactRelativePath: String,
        artifactSHA256: String,
        signature: Data
    ) {
        self.source = source
        self.version = version
        self.build = build
        self.artifactRelativePath = artifactRelativePath
        self.artifactSHA256 = artifactSHA256
        self.signature = signature
    }

    public var signingPayload: Data {
        [source, version, build, artifactRelativePath, artifactSHA256]
            .reduce(into: Data("mimi-app-update-v1".utf8)) { payload, field in
                var length = UInt64(field.utf8.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(contentsOf: field.utf8)
            }
    }
}

public struct AppUpdatePolicy: Equatable {
    public let expectedSource: String
    public let feedRootURL: URL
    public let trustedPublicKey: Data

    public init(expectedSource: String, feedRootURL: URL, trustedPublicKey: Data) {
        self.expectedSource = expectedSource
        self.feedRootURL = feedRootURL
        self.trustedPublicKey = trustedPublicKey
    }
}

public struct AppBundleIdentity: Codable, Equatable {
    public let version: String
    public let build: String

    public init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    public static func read(from appURL: URL) throws -> AppBundleIdentity {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else {
            throw AppUpdateError.invalidBundleIdentity
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let values = plist as? [String: Any],
            values["CFBundleIdentifier"] as? String == "com.akigarage.mimi",
            let version = values["CFBundleShortVersionString"] as? String,
            let build = values["CFBundleVersion"] as? String,
            ReleaseVersion(version) != nil,
            Int(build).map({ $0 > 0 }) == true
        else {
            throw AppUpdateError.invalidBundleIdentity
        }
        return AppBundleIdentity(version: version, build: build)
    }
}

public struct AppUpdateResult: Equatable {
    public let previousVersion: String
    public let installedVersion: String

    public init(previousVersion: String, installedVersion: String) {
        self.previousVersion = previousVersion
        self.installedVersion = installedVersion
    }
}

public enum AppUpdateRecoveryResult: Equatable {
    case nothingToRecover
    case rolledBack
    case committedUpdateRetained
}

enum AppUpdatePhase: Equatable {
    case afterBackup
    case afterInstall
    case afterCommit
    case afterRollback
}

enum AppUpdateInterruption: Error, Equatable {
    case simulatedCrash
}

public enum AppUpdateError: Error, Equatable {
    case invalidManifest
    case wrongSource
    case invalidArtifactPath
    case artifactMissing
    case checksumMismatch
    case invalidSignature
    case invalidPublicKey
    case invalidBundleIdentity
    case artifactIdentityMismatch
    case versionNotNewer
    case invalidStateDirectory
    case transactionFailed
    case recoveryFailed
}

struct ReleaseVersion: Comparable {
    let components: [Int]

    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        components = fields.compactMap { Int($0) }
        guard components.count == fields.count else { return nil }
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
