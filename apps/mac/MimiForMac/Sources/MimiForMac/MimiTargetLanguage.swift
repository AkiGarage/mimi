import Foundation

/// Gemini Live Translation target languages shared by the native UI and
/// session setup. Source-language selection is intentionally absent because
/// Gemini detects the input language automatically.
public struct MimiTargetLanguage: Sendable, Equatable, Identifiable {
    public static let defaultCode = "ja"

    private static let orderedCodes = """
    af kk ak km sq rw am ko ar lo hy lv az lt eu mk be ms bn ml bg mr my mn ca ne zh-Hans no nb zh-Hant fa hr pl cs pt-BR da pt-PT nl pa en ro et ru fil sr fi sd fr si gl sk ka sl de es el su gu sw ha sv he ta hi te hu th is tr id uk it ur ja uz jv vi kn zu
    """.split(separator: " ").map(String.init)

    public static let supported: [MimiTargetLanguage] = orderedCodes.map { MimiTargetLanguage(validatedCode: $0) }
    public static let supportedCodes = Set(orderedCodes)
    private static let canonicalCodeByLowercase = Dictionary(
        uniqueKeysWithValues: orderedCodes.map { ($0.lowercased(), $0) }
    )

    public let code: String
    public var id: String { code }

    public init(code: String) {
        self.code = Self.normalizedCode(code)
    }

    private init(validatedCode: String) {
        self.code = validatedCode
    }

    public static func normalizedCode(_ code: String?) -> String {
        guard let code else { return defaultCode }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return canonicalCodeByLowercase[normalized] ?? defaultCode
    }

    public func displayName(in locale: Locale = Locale(identifier: "ja")) -> String {
        locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }
}
