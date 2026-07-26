import Foundation

struct ChromeSetupOpenResult {
    let pathCopied: Bool
    let chromeOpened: Bool
    let errorDescription: String?
}

struct SetupRow: Identifiable {
    let id = UUID()
    let step: Int
    let kind: SetupRowKind
    let state: SetupState
}

enum SetupRowKind {
    case googleKey
    case chromeConnection
    case startListening
}

enum SetupStatusMessage: Equatable {
    case ready
    case running
    case repoMissing
    case extensionPathCopied
    case extensionPathCopyFailed
    case saveLimitSuccess
    case resetUsageSuccess
    case saveKeySuccess
    case helperSuccess
    case serverSuccess
    case chromeSetupSuccess
    case chromeSetupOpening
    case chromeInstallPending
    case chromePinRequired
    case chromeSetupFailed
    case chromeSetupOpenFailed(String?)
    case readyForChrome
    case needsAttention
    case custom(String)
}

enum SetupState: String {
    case notStarted = "未開始"
    case running = "実行中"
    case done = "完了"
    case needsAttention = "確認が必要"
    case ready = "準備完了"

    var systemImage: String {
        switch self {
        case .notStarted: "circle"
        case .running: "clock"
        case .done: "checkmark.circle.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .ready: "arrow.right.circle.fill"
        }
    }
}

enum SetupError: LocalizedError {
    case repoMissing

    var errorDescription: String? {
        "Mimiのフォルダが見つかりません。"
    }
}

enum SetupActionError: Error {
    case chromeExtensionNotVerified
}
