import Foundation

public struct MimiMenuBarPresentation: Equatable, Sendable {
    public let title: String
    public let value: String
    public let symbolName: String
    public let shouldPulse: Bool

    public init(title: String, value: String, symbolName: String, shouldPulse: Bool) {
        self.title = title
        self.value = value
        self.symbolName = symbolName
        self.shouldPulse = shouldPulse
    }
}

public enum MimiMenuBarPresentationPolicy {
    public static func presentation(
        for state: MimiUIState,
        locale: Locale
    ) -> MimiMenuBarPresentation {
        MimiMenuBarPresentation(
            title: state.title(locale: locale),
            value: state.message(locale: locale),
            symbolName: state.symbolName,
            shouldPulse: state == .listening
        )
    }
}

public enum MimiMenuBarPulsePolicy {
    public static let cycleDuration: TimeInterval = 2.4
    public static let minimumOpacity = 0.72

    public static func opacity(
        elapsed: TimeInterval,
        shouldPulse: Bool,
        reduceMotion: Bool
    ) -> Double {
        guard shouldPulse, !reduceMotion, elapsed.isFinite else { return 1 }
        let remainder = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        let normalized = (remainder >= 0 ? remainder : remainder + cycleDuration) / cycleDuration
        let wave = (1 - cos(normalized * 2 * .pi)) / 2
        return 1 - ((1 - minimumOpacity) * wave)
    }
}

public enum MimiMenuBarCommand: CaseIterable, Hashable, Sendable {
    case openWindow
    case primaryAction
    case settings
    case quit
}

@MainActor
public struct MimiMenuBarCommandRouter {
    private let openWindow: @MainActor () -> Void
    private let performPrimaryAction: @MainActor () -> Void
    private let showSettings: @MainActor () -> Void
    private let quit: @MainActor () -> Void

    public init(
        openWindow: @escaping @MainActor () -> Void,
        performPrimaryAction: @escaping @MainActor () -> Void,
        showSettings: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void
    ) {
        self.openWindow = openWindow
        self.performPrimaryAction = performPrimaryAction
        self.showSettings = showSettings
        self.quit = quit
    }

    public func perform(_ command: MimiMenuBarCommand) {
        switch command {
        case .openWindow: openWindow()
        case .primaryAction: performPrimaryAction()
        case .settings: showSettings()
        case .quit: quit()
        }
    }
}
