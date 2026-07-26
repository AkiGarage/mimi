import Foundation

public struct SetupLaunchOptions: Equatable {
    public let freshSetupPreview: Bool
    public let chromeSetupPreview: Bool

    public init(arguments: [String] = CommandLine.arguments) {
        self.freshSetupPreview = arguments.contains("--fresh-setup-preview")
        self.chromeSetupPreview = arguments.contains("--chrome-setup-preview")
    }
}
