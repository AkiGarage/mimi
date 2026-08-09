import AppKit
import Foundation

struct ChromeURLLaunchResult: Equatable {
    let opened: Bool
    let errorDescription: String?

    static let success = ChromeURLLaunchResult(opened: true, errorDescription: nil)

    static func failure(_ description: String) -> ChromeURLLaunchResult {
        ChromeURLLaunchResult(opened: false, errorDescription: description)
    }
}

@MainActor
protocol ChromeURLLaunching {
    func openChromeURL(_ url: URL) async -> ChromeURLLaunchResult
    func openDefaultURL(_ url: URL)
}

@MainActor
struct SystemChromeURLLauncher: ChromeURLLaunching {
    private let workspace: WorkspaceOpening

    init(workspace: WorkspaceOpening = NSWorkspace.shared) {
        self.workspace = workspace
    }

    func openChromeURL(_ url: URL) async -> ChromeURLLaunchResult {
        guard let chromeURL = workspace.chromeApplicationURL() else {
            return .failure("Google Chrome is not installed or could not be found.")
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await workspace.openURLsInChrome([url], applicationURL: chromeURL, configuration: configuration)
    }

    func openDefaultURL(_ url: URL) {
        workspace.openDefault(url)
    }
}

@MainActor
protocol WorkspaceOpening {
    func chromeApplicationURL() -> URL?
    func openDefault(_ url: URL)
    func openURLsInChrome(
        _ urls: [URL],
        applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async -> ChromeURLLaunchResult
}

extension NSWorkspace: WorkspaceOpening {
    func chromeApplicationURL() -> URL? {
        urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    func openDefault(_ url: URL) {
        open(url)
    }

    func openURLsInChrome(
        _ urls: [URL],
        applicationURL: URL,
        configuration: NSWorkspace.OpenConfiguration
    ) async -> ChromeURLLaunchResult {
        await withCheckedContinuation { continuation in
            open(urls, withApplicationAt: applicationURL, configuration: configuration) { app, error in
                if let error {
                    continuation.resume(returning: .failure(error.localizedDescription))
                    return
                }
                app?.activate(options: [.activateAllWindows])
                continuation.resume(returning: .success)
            }
        }
    }
}

@MainActor
protocol ClipboardWriting {
    func writeString(_ value: String) -> Bool
}

@MainActor
struct SystemClipboardWriter: ClipboardWriting {
    func writeString(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
}
