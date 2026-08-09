import AppKit
import MimiForMac

/// Uses QuickTime Player's public scripting dictionary to distinguish playing
/// documents from paused documents. Other applications return `nil` and keep
/// the generic ScreenCaptureKit window context.
struct QuickTimePlaybackContextProvider: PlaybackWindowContextProviding {
    private static let bundleIdentifier = "com.apple.QuickTimePlayerX"
    private static let separator = "\u{001E}"

    func playingWindowNames(for application: AudioSource) async -> [String]? {
        guard application.bundleIdentifier == Self.bundleIdentifier else { return nil }
        return await Task.detached(priority: .utility) {
            Self.queryPlayingDocumentNames()
        }.value
    }

    private static func queryPlayingDocumentNames() -> [String]? {
        let source = """
        tell application id "com.apple.QuickTimePlayerX"
            set output to ""
            repeat with movieDocument in documents
                if playing of movieDocument is true then
                    set output to output & (name of movieDocument as text) & ASCII character 30
                end if
            end repeat
            return output
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let value = result.stringValue else { return nil }
        return value.split(separator: Character(separator), omittingEmptySubsequences: true)
            .map(String.init)
    }
}
