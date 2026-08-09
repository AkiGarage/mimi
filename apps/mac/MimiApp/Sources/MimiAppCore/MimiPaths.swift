import Foundation

public struct MimiPaths: Equatable {
    public let root: URL
    public let extensionDirectory: URL
    public let localServerDirectory: URL
    public let nativeHostDirectory: URL
    public let envFileURL: URL
    public let usageFileURL: URL
    public let runtimeEnvironment: [String: String]

    public static func discover(
        startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        resourceURL: URL? = Bundle.main.resourceURL,
        applicationSupportURL: URL = defaultApplicationSupportURL()
    ) -> MimiPaths? {
        if let repo = discoverRepoLayout(startingAt: start) {
            return repo
        }
        if let resourceURL, let bundled = discoverBundledLayout(resourceURL: resourceURL, applicationSupportURL: applicationSupportURL) {
            return bundled
        }
        return nil
    }

    private static func discoverRepoLayout(startingAt start: URL) -> MimiPaths? {
        var candidate = start.standardizedFileURL
        let fileManager = FileManager.default
        while true {
            if looksLikeRepoRoot(candidate, fileManager: fileManager) {
                return MimiPaths(
                    root: candidate,
                    extensionDirectory: candidate.appendingPathComponent("apps/mac/extension"),
                    localServerDirectory: candidate.appendingPathComponent("apps/mac/local-server"),
                    nativeHostDirectory: candidate.appendingPathComponent("apps/mac/native-host"),
                    envFileURL: candidate.appendingPathComponent("apps/mac/local-server/.env"),
                    usageFileURL: candidate.appendingPathComponent("tmp/jp-dub-usage.json"),
                    runtimeEnvironment: [:]
                )
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    private static func discoverBundledLayout(resourceURL: URL, applicationSupportURL: URL) -> MimiPaths? {
        let fileManager = FileManager.default
        let localServer = resourceURL.appendingPathComponent("local-server")
        let nativeHost = resourceURL.appendingPathComponent("native-host")
        let extensionDirectory = resourceURL.appendingPathComponent("extension")
        guard
            fileManager.fileExists(atPath: localServer.appendingPathComponent("package.json").path),
            fileManager.fileExists(atPath: nativeHost.appendingPathComponent("package.json").path)
        else {
            return nil
        }

        let envFile = applicationSupportURL.appendingPathComponent("local-server/.env")
        let usageFile = applicationSupportURL.appendingPathComponent("tmp/jp-dub-usage.json")
        let setupProgressFile = applicationSupportURL.appendingPathComponent("tmp/mimi-setup-progress.json")
        return MimiPaths(
            root: resourceURL,
            extensionDirectory: extensionDirectory,
            localServerDirectory: localServer,
            nativeHostDirectory: nativeHost,
            envFileURL: envFile,
            usageFileURL: usageFile,
            runtimeEnvironment: [
                "JP_DUB_ENV_FILE": envFile.path,
                "JP_DUB_USAGE_FILE": usageFile.path,
                "JP_DUB_SETUP_PROGRESS_FILE": setupProgressFile.path,
                "MIMI_EXTENSION_ORIGIN": ExtensionOriginResolver().fixedOrigin()
            ]
        )
    }

    private static func looksLikeRepoRoot(_ url: URL, fileManager: FileManager) -> Bool {
        let localServer = url.appendingPathComponent("apps/mac/local-server/package.json")
        let extensionManifest = url.appendingPathComponent("apps/mac/extension/manifest.json")
        return fileManager.fileExists(atPath: localServer.path)
            && fileManager.fileExists(atPath: extensionManifest.path)
    }

    public static func defaultApplicationSupportURL() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Mimi", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Mimi")
    }
}

public struct ExtensionOriginResolver {
    public static let canonicalExtensionId = "oknekoaclmnljnlpmffphpiflcdeibgg"
    public static let fixedPopupURL = "chrome-extension://\(canonicalExtensionId)/src/popup.html"

    public init() {}

    public func fixedOrigin() -> String {
        "chrome-extension://\(Self.canonicalExtensionId)"
    }
}
