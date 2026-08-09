import Foundation

public struct SetupRunner {
    private let paths: MimiPaths
    private let runner: any SetupCommandRunning
    private let originResolver: ExtensionOriginResolver
    private let environment: [String: String]

    public init(
        paths: MimiPaths,
        runner: any SetupCommandRunning = CommandRunner(),
        originResolver: ExtensionOriginResolver = ExtensionOriginResolver(),
        environment: [String: String] = [:]
    ) {
        self.paths = paths
        self.runner = runner
        self.originResolver = originResolver
        self.environment = paths.runtimeEnvironment.merging(environment) { _, new in new }
    }

    public func installNativeHost() async throws -> CommandResult {
        try await runner.runNodeScript(
            "scripts/install.js",
            arguments: ["--extension-origin=\(extensionOrigin)"],
            workingDirectory: paths.nativeHostDirectory,
            environment: environment
        )
    }

    private var extensionOrigin: String {
        environment["MIMI_EXTENSION_ORIGIN"] ?? originResolver.fixedOrigin()
    }

    public func checkNativeHost() async throws -> CommandResult {
        try await runner.runNodeScript(
            "scripts/doctor.js",
            arguments: [],
            workingDirectory: paths.nativeHostDirectory,
            environment: environment
        )
    }

    public func runConnectionTest() async throws -> CommandResult {
        try await runner.runNodeScript(
            "scripts/diagnose-real.js",
            arguments: [],
            workingDirectory: paths.localServerDirectory,
            environment: environment
        )
    }

    public func startLocalServer() async throws -> CommandResult {
        try await runner.runNodeScript(
            "scripts/start-detached.js",
            arguments: [],
            workingDirectory: paths.localServerDirectory,
            environment: environment
        )
    }

    public func prepareChromeConnection() async throws -> CommandResult {
        let install = try await installNativeHost()
        guard install.succeeded else { return install }

        let hostCheck = try await checkNativeHost()
        guard hostCheck.succeeded else { return hostCheck }

        return try await restartLocalServer()
    }

    public func restartLocalServer() async throws -> CommandResult {
        let stop = try await runner.runNodeScript(
            "scripts/stop.js",
            arguments: [],
            workingDirectory: paths.localServerDirectory,
            environment: environment
        )
        guard stop.succeeded else { return stop }
        return try await runner.runNodeScript(
            "scripts/start-detached.js",
            arguments: [],
            workingDirectory: paths.localServerDirectory,
            environment: environment.merging(["JP_DUB_RESTART_EXISTING": "true"]) { _, new in new }
        )
    }
}
