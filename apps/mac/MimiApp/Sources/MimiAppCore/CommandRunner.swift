import Foundation

public struct CommandResult: Equatable {
    public let command: String
    public let exitCode: Int32
    public let output: String

    public init(command: String, exitCode: Int32, output: String) {
        self.command = command
        self.exitCode = exitCode
        self.output = output
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public protocol SetupCommandRunning {
    func runNodeScript(
        _ script: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> CommandResult
}

public struct CommandRunner: SetupCommandRunning {
    private let node: NodeRuntime

    public init(node: NodeRuntime = NodeRuntime()) {
        self.node = node
    }

    public func runNodeScript(
        _ script: String,
        arguments: [String] = [],
        workingDirectory: URL,
        environment: [String: String] = [:]
    ) async throws -> CommandResult {
        let invocation = node.invocation(forScript: script, arguments: arguments)
        return try await run(
            executable: invocation.executable,
            arguments: invocation.arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String] = [:]
    ) async throws -> CommandResult {
        try await Task.detached {
            try runProcess(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
        }.value
    }
}

public struct NodeRuntime {
    public let resourceURL: URL?
    public let environment: [String: String]

    public init(resourceURL: URL? = Bundle.main.resourceURL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.resourceURL = resourceURL
        self.environment = environment
    }

    public func invocation(forScript script: String, arguments: [String] = []) -> (executable: URL, arguments: [String]) {
        if let bundledNode = bundledNodeURL(), FileManager.default.isExecutableFile(atPath: bundledNode.path) {
            return (bundledNode, [script] + arguments)
        }
        if let override = environment["MIMI_NODE_PATH"], !override.isEmpty {
            return (URL(fileURLWithPath: override), [script] + arguments)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["node", script] + arguments)
    }

    private func bundledNodeURL() -> URL? {
        resourceURL?
            .appendingPathComponent("node")
            .appendingPathComponent("bin")
            .appendingPathComponent("node")
    }
}

private func runProcess(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String]
) throws -> CommandResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8) ?? ""
    return CommandResult(
        command: ([executable.path] + arguments).joined(separator: " "),
        exitCode: process.terminationStatus,
        output: redactSecrets(text)
    )
}

public func redactSecrets(_ value: String) -> String {
    value
        .replacingOccurrences(
            of: #"AIza[0-9A-Za-z_-]{20,}"#,
            with: "[redacted]",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?i)(api[_-]?key|authorization|token|secret|key)=\S+"#,
            with: "$1=[redacted]",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
