import CryptoKit
import Foundation

public enum AppBundleDigest {
    public static func sha256(at appURL: URL) throws -> String {
        let fileManager = FileManager.default
        let rootURL = appURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppUpdateError.artifactMissing
        }
        let entries = try bundleEntries(at: rootURL, fileManager: fileManager)
        var hasher = SHA256()
        for entry in entries {
            let normalizedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
            let relativePath = String(normalizedEntry.path.dropFirst(rootURL.path.count + 1))
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AppUpdateError.invalidArtifactPath }
            if values.isDirectory == true {
                appendField("D:\(relativePath)", to: &hasher)
            } else if values.isRegularFile == true {
                appendField("F:\(relativePath)", to: &hasher)
                try appendFile(entry, to: &hasher)
            } else {
                throw AppUpdateError.invalidArtifactPath
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func bundleEntries(at root: URL, fileManager: FileManager) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var traversalFailed = false
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                traversalFailed = true
                return false
            }
        ) else {
            throw AppUpdateError.artifactMissing
        }
        var entries: [URL] = []
        for case let url as URL in enumerator { entries.append(url) }
        guard !traversalFailed else { throw AppUpdateError.invalidArtifactPath }
        return entries.sorted { $0.path < $1.path }
    }

    private static func appendField(_ value: String, to hasher: inout SHA256) {
        appendData(Data(value.utf8), to: &hasher)
    }

    private static func appendData(_ data: Data, to hasher: inout SHA256) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }

    private static func appendFile(_ url: URL, to hasher: inout SHA256) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else { throw AppUpdateError.invalidArtifactPath }
        var length = UInt64(fileSize).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }
}
