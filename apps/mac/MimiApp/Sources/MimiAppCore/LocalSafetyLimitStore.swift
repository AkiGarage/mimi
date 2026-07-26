import Foundation

public enum LocalSafetyLimitError: LocalizedError, Equatable {
    case invalidLimit

    public var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "Enter a positive monthly safety limit."
        }
    }
}

public struct LocalSafetyLimitSummary: Equatable {
    public let monthlyLimitEnabled: Bool
    public let usageExists: Bool
    public let limitMinutes: Double
    public let usedMinutes: Double
    public let remainingMinutes: Double
    public let usagePath: URL
}

public struct LocalSafetyLimitStore {
    public static let defaultLimitMinutes = 30.0

    private let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public init(paths: MimiPaths, fileManager: FileManager = .default) {
        self.root = paths.root
        self.fileManager = fileManager
        self.envFileURLOverride = paths.envFileURL
        self.usageFileURLOverride = paths.usageFileURL
    }

    private var envFileURLOverride: URL? = nil
    private var usageFileURLOverride: URL? = nil

    public var envFileURL: URL {
        if let envFileURLOverride {
            return envFileURLOverride
        }
        return root.appendingPathComponent("apps/mac/local-server/.env")
    }

    public var usageFileURL: URL {
        if let usageFileURLOverride {
            return usageFileURLOverride
        }
        return root.appendingPathComponent("tmp/jp-dub-usage.json")
    }

    public func readLimitMinutes() -> Double {
        guard
            let contents = try? String(contentsOf: envFileURL, encoding: .utf8),
            let line = contents.split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap({ limitValue(from: String($0)) })
                .first,
            let minutes = Double(line),
            minutes > 0
        else {
            return Self.defaultLimitMinutes
        }
        return minutes
    }

    public func readMonthlyLimitEnabled() -> Bool {
        guard
            let contents = try? String(contentsOf: envFileURL, encoding: .utf8)
        else {
            return false
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let line = lines
                .compactMap({ envValue(from: String($0), key: "JP_DUB_MONTHLY_LIMIT_ENABLED") })
                .first {
            return isEnabledValue(line)
        }
        let hasLegacyLimit = lines.contains { limitValue(from: $0) != nil }
        let freeTierMode = lines
            .compactMap({ envValue(from: $0, key: "JP_DUB_FREE_TIER_MODE") })
            .first
            .map(isEnabledValue) ?? false
        return hasLegacyLimit && !freeTierMode
    }

    @discardableResult
    public func saveLimitMinutes(_ minutes: Double) throws -> Double {
        try saveMonthlyLimit(enabled: true, minutes: minutes)
    }

    @discardableResult
    public func saveMonthlyLimit(enabled: Bool, minutes: Double) throws -> Double {
        guard minutes.isFinite, minutes > 0 else {
            throw LocalSafetyLimitError.invalidLimit
        }

        let enabledLine = "JP_DUB_MONTHLY_LIMIT_ENABLED=\(enabled ? "true" : "false")"
        let limitLine = "JP_DUB_MONTHLY_LIMIT_MINUTES=\(formatMinutes(minutes))"
        let existing = (try? String(contentsOf: envFileURL, encoding: .utf8)) ?? ""
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        replaceOrAppend(&lines, key: "JP_DUB_MONTHLY_LIMIT_ENABLED", line: enabledLine)
        replaceOrAppend(&lines, key: "JP_DUB_MONTHLY_LIMIT_MINUTES", line: limitLine)

        try fileManager.createDirectory(at: envFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(lines.joined(separator: "\n"))\n".write(to: envFileURL, atomically: true, encoding: .utf8)
        return minutes
    }

    @discardableResult
    public func resetUsageCounter(now: Date = Date()) throws -> URL? {
        guard fileManager.fileExists(atPath: usageFileURL.path) else {
            return nil
        }
        let backup = usageFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("jp-dub-usage.json.reset-backup.\(timestamp(now))")
        try fileManager.moveItem(at: usageFileURL, to: backup)
        return backup
    }

    public func readSummary(now: Date = Date()) -> LocalSafetyLimitSummary {
        let monthlyLimitEnabled = readMonthlyLimitEnabled()
        let limitMinutes = readLimitMinutes()
        let limitSeconds = limitMinutes * 60
        let usage = readUsage()
        let currentMonth = monthKey(now)
        let storedMonth = usage?.month ?? currentMonth
        let sameMonth = storedMonth == currentMonth
        let usedSeconds = sameMonth ? min(limitSeconds, max(0, usage?.usedSeconds ?? 0)) : 0
        let remainingSeconds = max(0, limitSeconds - usedSeconds)
        return LocalSafetyLimitSummary(
            monthlyLimitEnabled: monthlyLimitEnabled,
            usageExists: usage != nil,
            limitMinutes: limitMinutes,
            usedMinutes: usedSeconds / 60,
            remainingMinutes: remainingSeconds / 60,
            usagePath: usageFileURL
        )
    }

    private func readUsage() -> (month: String?, usedSeconds: Double)? {
        guard
            let data = try? Data(contentsOf: usageFileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return (object["month"] as? String, positiveNumber(object["usedSeconds"]))
    }

    private func limitValue(from line: String) -> String? {
        envValue(from: line, key: "JP_DUB_MONTHLY_LIMIT_MINUTES")
    }

    private func envValue(from line: String, key expectedKey: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<separator]
            .replacingOccurrences(of: "export ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard key == expectedKey else {
            return nil
        }
        return String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private func replaceOrAppend(_ lines: inout [String], key: String, line: String) {
        for index in lines.indices where envValue(from: lines[index], key: key) != nil {
            lines[index] = line
            return
        }

        if lines == [""] || lines.isEmpty {
            lines = [line]
        } else {
            lines.append(line)
        }
    }

    private func positiveNumber(_ value: Any?) -> Double {
        if let number = value as? NSNumber, number.doubleValue > 0 {
            return number.doubleValue
        }
        if let text = value as? String, let number = Double(text), number > 0 {
            return number
        }
        return 0
    }

    private func isEnabledValue(_ value: String) -> Bool {
        ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private func formatMinutes(_ minutes: Double) -> String {
        if minutes.rounded() == minutes {
            return String(Int(minutes))
        }
        return String(format: "%.2f", minutes)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func monthKey(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 1970, components.month ?? 1)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
