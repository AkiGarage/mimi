public enum SetupDisplayLanguage: String, CaseIterable, Identifiable {
    case japanese = "ja"
    case english = "en"

    public static let releaseDefault = SetupDisplayLanguage.english

    public var id: String { rawValue }
}

public struct SetupWizardCopy {
    public let languageControlLabel: String
    public let japaneseLanguageName: String
    public let englishLanguageName: String
    public let sidebarSubtitle: String
    public let currentStatusTitle: String
    public let headerTitle: String
    public let setupSummary: String
    public let providerPanelTitle: String
    public let providerPanelExplanation: String
    public let providerGeminiLabel: String
    public let providerGeminiBadge: String
    public let providerGeminiDescription: String
    public let providerOpenAILabel: String
    public let providerOpenAIBadge: String
    public let providerOpenAIDescription: String
    public let providerSaving: String
    public let providerActiveSessionWarning: String
    public let apiKeyTitle: String
    public let apiKeyExplanation: String
    public let accountGuidance: String
    public let paidPathGuidance: String
    public let guidedKeySteps: String
    public let replaceKeyGuidance: String
    public let trustExplanation: String
    public let apiKeyPlaceholder: String
    public let openAIStudioFirstRun: String
    public let openAIStudioAPIKeys: String
    public let saveAndTest: String
    public let googleKeyReady: String
    public let changeGoogleKey: String
    public let keychainHelpTitle: String
    public let keychainLocationLabel: String
    public let keychainLocationValue: String
    public let keychainItemNameLabel: String
    public let keychainAccountLabel: String
    public let keychainPasswordsAppNote: String
    public let openKeychainAccess: String
    public let copyKeychainItemName: String
    public let copiedKeychainItemName: String
    public let optionalSettingsLabel: String
    public let safetyPanelTitle: String
    public let safetyToggleTitle: String
    public let paidKeyLimitFieldLabel: String
    public let safetyStepperLabel: String
    public let minutesPerMonth: String
    public let saveLimitAndRestart: String
    public let resetUsageCounter: String
    public let safetyExplanation: String
    public let noMonthlyProtectionTitle: String
    public let freeKeyNoMonthlyLimit: String
    public let remainingMinutesPrefix: String
    public let remainingMinutesSuffix: String
    public let usedThisMonthPrefix: String
    public let usedThisMonthSeparator: String
    public let usedThisMonthSuffix: String
    public let helperPanelTitle: String
    public let chromeHelperExplanation: String
    public let prepareChromeConnection: String
    public let prepareChromeConnectionRunning: String
    public let chromeManualConfirmation: String
    public let chromeGuideTitle: String
    public let chromeInstallSteps: [String]
    public let chromePathWillCopy: String
    public let chromePathCopied: String
    public let chromePathCopyFailed: String
    public let chromeReturnToMimi: String
    public let chromeConnectionReady: String
    public let chromePinInstruction: String
    public let chromePinDetected: String
    public let chromeTroubleshootingTitle: String
    public let openChromeExtension: String
    public let installHelper: String
    public let startServer: String
    public let openStatus: String
    public let finalPanelTitle: String
    public let finalStepOne: String
    public let finalStepTwo: String
    public let finalStepThree: String
    public let statusRunning: String
    public let messageReady: String
    public let messageRepoMissing: String
    public let messageExtensionPathCopied: String
    public let messageExtensionPathCopyFailed: String
    public let messageSaveLimitSuccess: String
    public let messageResetUsageSuccess: String
    public let messageSaveKeySuccess: String
    public let messageHelperSuccess: String
    public let messageServerSuccess: String
    public let messageChromeSetupSuccess: String
    public let messageChromeSetupOpening: String
    public let messageChromeInstallPending: String
    public let messageChromePinRequired: String
    public let messageChromeSetupFailed: String
    public let messageChromeSetupOpenFailed: String
    public let messageReadyForChrome: String
    public let messageNeedsAttention: String
    public let rowGoogleKey: String
    public let rowChromeConnection: String
    public let rowStartListening: String
    public let stateNotStarted: String
    public let stateRunning: String
    public let stateDone: String
    public let stateNeedsAttention: String
    public let stateReady: String

}

public enum OnboardingCopy {
    public static let aiStudioHomeURL = "https://aistudio.google.com/"
    public static let aiStudioAPIKeysURL = "https://aistudio.google.com/api-keys"

    public static func copy(for language: SetupDisplayLanguage) -> SetupWizardCopy {
        switch language {
        case .japanese:
            japanese
        case .english:
            english
        }
    }

    public static let setupSummary = japanese.setupSummary
    public static let apiKeyTitle = japanese.apiKeyTitle
    public static let apiKeyExplanation = japanese.apiKeyExplanation
    public static let accountGuidance = japanese.accountGuidance
    public static let paidPathGuidance = japanese.paidPathGuidance
    public static let guidedKeySteps = japanese.guidedKeySteps
    public static let replaceKeyGuidance = japanese.replaceKeyGuidance
    public static let trustExplanation = japanese.trustExplanation
    public static let apiKeyPlaceholder = japanese.apiKeyPlaceholder
    public static let openAIStudioFirstRun = japanese.openAIStudioFirstRun
    public static let openAIStudioAPIKeys = japanese.openAIStudioAPIKeys
    public static let saveAndTest = japanese.saveAndTest
    public static let googleKeyReady = japanese.googleKeyReady
    public static let changeGoogleKey = japanese.changeGoogleKey
    public static let keychainHelpTitle = japanese.keychainHelpTitle
    public static let optionalSettingsLabel = japanese.optionalSettingsLabel
    public static let chromeHelperExplanation = japanese.chromeHelperExplanation
    public static let prepareChromeConnection = japanese.prepareChromeConnection
    public static let prepareChromeConnectionRunning = japanese.prepareChromeConnectionRunning
    public static let chromeManualConfirmation = japanese.chromeManualConfirmation
    public static let chromeConnectionReady = japanese.chromeConnectionReady
    public static let chromeTroubleshootingTitle = japanese.chromeTroubleshootingTitle
    public static let finalStepOne = japanese.finalStepOne
    public static let finalStepTwo = japanese.finalStepTwo
    public static let finalStepThree = japanese.finalStepThree
    public static let safetyExplanation = japanese.safetyExplanation

    private static let japanese = SetupWizardCopy(
        languageControlLabel: "表示言語",
        japaneseLanguageName: "日本語",
        englishLanguageName: "English",
        sidebarSubtitle: "設定・状態センター",
        currentStatusTitle: "現在の状態",
        headerTitle: "Mimi Setup for Chrome",
        setupSummary: "番号の順に進めると、MimiをChromeで使えるようになります。Mimiは元の声を置き換えるのではなく、AIの同時通訳・翻訳音声を重ねて聞けるようにします。",
        providerPanelTitle: "翻訳品質",
        providerPanelExplanation: "通常は無料のGeminiを使います。より自然な日本語を求め、API課金を理解して選ぶ場合だけGPT Realtimeを使えます。Mimiが自動でGPTへ切り替えることはありません。",
        providerGeminiLabel: "Gemini Live",
        providerGeminiBadge: "無料・おすすめ",
        providerGeminiDescription: "Mimiの標準設定。無料枠を優先して使います。",
        providerOpenAILabel: "GPT Realtime",
        providerOpenAIBadge: "有料・高品質",
        providerOpenAIDescription: "API利用料がかかります。より自然な日本語を重視する時に選びます。",
        providerSaving: "翻訳エンジンを保存中…",
        providerActiveSessionWarning: "翻訳中は切り替えできません。Chrome拡張で停止してから変更してください。",
        apiKeyTitle: "Googleの翻訳準備",
        apiKeyExplanation: "初めてGoogle AI Studioを使う人は、AI Studioを開いてGoogleアカウントでログインします。利用規約の画面が出たら、必須の同意チェックを入れて「続行」を押してください。",
        accountGuidance: "そのあとAPIキーのページを開きます。最初から表示されているGemini APIキーがある場合は、その行のコピーボタンでコピーできます。キーが見当たらない場合だけ、AI Studioの画面で無料で使えるGemini APIキーを作ります。",
        paidPathGuidance: "Googleのサービス改善への利用を許可したくない場合は、Google Cloudの有料APIを使う方法を選んでください。Mimiが有料課金を自動で始めることはありません。課金が有効なAPIキーを使う場合だけ、任意で時間の目安を入れておけます。",
        guidedKeySteps: "手順: AI Studioを開く -> 必要なら同意して続行 -> APIキーのページを開く -> キー行のコピーボタン -> この欄に貼り付け",
        replaceKeyGuidance: "APIキーを差し替える場合も、新しいキーをここに貼り付けて保存すると、このMacのKeychain側だけが更新されます。",
        trustExplanation: "キーはmacOS Keychainに保存され、Chrome拡張には保存しません。chat、GitHub、screenshots、docs、.envにも貼り付けないでください。",
        apiKeyPlaceholder: "AI Studioでコピーしたキーを貼り付け",
        openAIStudioFirstRun: "初めての人: AI Studioを開く",
        openAIStudioAPIKeys: "完了済みの人: APIキーのページ",
        saveAndTest: "Keychainに保存 / 差し替えて接続テスト",
        googleKeyReady: "Google翻訳用キーはKeychainに保存済みです",
        changeGoogleKey: "APIキーを確認・差し替える",
        keychainHelpTitle: "Keychainで保存場所を確認する",
        keychainLocationLabel: "保存先",
        keychainLocationValue: "キーチェーンアクセス → ログイン → すべての項目（またはパスワード）",
        keychainItemNameLabel: "項目名",
        keychainAccountLabel: "アカウント",
        keychainPasswordsAppNote: "macOSの「パスワード」アプリには表示されない場合があります。「キーチェーンアクセス」で探してください。",
        openKeychainAccess: "キーチェーンアクセスを開く",
        copyKeychainItemName: "項目名をコピー",
        copiedKeychainItemName: "コピーしました",
        optionalSettingsLabel: "任意設定",
        safetyPanelTitle: "API利用の設定",
        safetyToggleTitle: "有料・課金が有効なAPIキー用の月間保護を使う",
        paidKeyLimitFieldLabel: "有料キー用の任意の時間設定",
        safetyStepperLabel: "5分ずつ調整",
        minutesPerMonth: "分 / 月",
        saveLimitAndRestart: "設定を保存して再起動",
        resetUsageCounter: "使用記録をリセット",
        safetyExplanation: "無料のGemini APIキーなら、Mimi側で月の利用時間を気にせず使えます。課金が有効なAPIキーを使う場合だけ、任意で時間の目安を入れておけます。使い忘れ防止の自動停止は別の設定で、初期値は30分です。使用量リセット時は、既存の使用量ファイルがあればローカルバックアップを作成します。",
        noMonthlyProtectionTitle: "月間保護なし",
        freeKeyNoMonthlyLimit: "無料キーならMimi側の月間上限はありません",
        remainingMinutesPrefix: "残り",
        remainingMinutesSuffix: "分",
        usedThisMonthPrefix: "今月",
        usedThisMonthSeparator: "/",
        usedThisMonthSuffix: "分 使用",
        helperPanelTitle: "Chromeとつなぐ",
        chromeHelperExplanation: "Mimiがヘルパー登録とサーバー起動を自動で行い、Chrome拡張機能の画面を開いてフォルダのパスをコピーします。Chromeで下の番号順に操作してください。拡張自身から実際の通信が届くまで接続完了にはしません。",
        prepareChromeConnection: "Chrome設定を開始（ページを開いてパスをコピー）",
        prepareChromeConnectionRunning: "Chrome設定を開始中...",
        chromeManualConfirmation: "開発体験版だけ必要な手順です。追加・有効化の安全確認はChrome上でユーザーが行います。Chrome Web Store配布後は「Chromeに追加」の確認だけになる予定です。追加済みの場合はMimiがポップアップを開いて再接続します。",
        chromeGuideTitle: "Chromeでこの順番に進める",
        chromeInstallSteps: [
            "Chrome拡張機能ページを開き、Mimiフォルダのパスをコピーする（上の開始ボタンで自動実行）",
            "デベロッパー モードをオンにし、「パッケージ化されていない拡張機能を読み込む」でMimiを選択する",
            "Chrome右上のパズルアイコンを押し、Mimiのピンをオンにする",
            "ツールバーのMimiを開く（実接続を受信した時だけ完了）"
        ],
        chromePathWillCopy: "上の開始ボタンを押すと、Mimiがパスを自動コピーします",
        chromePathCopied: "Mimiフォルダのパスはクリップボードにコピー済みです",
        chromePathCopyFailed: "自動コピーできませんでした。下のパスを選択してコピーしてください",
        chromeReturnToMimi: "Mimiポップアップを開いた時点で接続とピン留めを自動確認し、チェック操作なしで次へ進みます。",
        chromeConnectionReady: "Chrome拡張からMimiへの実接続を確認しました",
        chromePinInstruction: "Chrome右上の拡張機能（パズル）を開き、Mimiのピンをオンにしてください。完了状態は自動で確認します。",
        chromePinDetected: "Chromeのツールバーへのピン留めを確認しました",
        chromeTroubleshootingTitle: "うまくいかないとき",
        openChromeExtension: "Chrome拡張画面をもう一度開く",
        installHelper: "ヘルパーを修復",
        startServer: "サーバーを起動",
        openStatus: "状態を確認",
        finalPanelTitle: "聞き始める",
        finalStepOne: "YouTubeまたはX Webの公開動画を開く",
        finalStepTwo: "ChromeツールバーのMimiを開く",
        finalStepThree: "聞く言語を選び、「開始」を押す",
        statusRunning: "実行中",
        messageReady: "準備OK",
        messageRepoMissing: "Mimiのフォルダが見つかりません",
        messageExtensionPathCopied: "Chrome拡張機能フォルダをコピーしました",
        messageExtensionPathCopyFailed: "Chrome拡張機能フォルダを自動コピーできませんでした",
        messageSaveLimitSuccess: "API利用の設定を保存し、ローカルサーバーを再起動しました",
        messageResetUsageSuccess: "このMacの使用量をリセットしました",
        messageSaveKeySuccess: "APIキーを保存し、接続テストに成功しました",
        messageHelperSuccess: "ヘルパーをインストールして確認しました",
        messageServerSuccess: "ローカルサーバーを起動しました",
        messageChromeSetupSuccess: "Chrome拡張からMimiへの実接続を確認しました",
        messageChromeSetupOpening: "Chromeで chrome://extensions/ を開き、Mimiフォルダのパスをコピーしています。Chromeが前面に出たら下の手順を続けてください。",
        messageChromeInstallPending: "サーバーは起動しました。ChromeでMimiを追加してください。拡張から実通信が届くまで完了にはなりません。",
        messageChromePinRequired: "Chrome拡張の実接続を確認しました。Mimiをピン留めして、ツールバーのMimiを1回開いてください。",
        messageChromeSetupFailed: "Chrome拡張からの実接続を確認できませんでした。追加・有効化後にもう一度実行してください。",
        messageChromeSetupOpenFailed: "Chromeで chrome://extensions/ を自動で開けませんでした。Chromeを開いて chrome://extensions/ を入力し、下のMimiフォルダパスを使ってください。",
        messageReadyForChrome: "Chromeで使えます",
        messageNeedsAttention: "確認が必要です",
        rowGoogleKey: "Google翻訳用キー",
        rowChromeConnection: "Chromeとつなぐ",
        rowStartListening: "聞き始める",
        stateNotStarted: "未開始",
        stateRunning: "実行中",
        stateDone: "完了",
        stateNeedsAttention: "確認が必要",
        stateReady: "準備完了"
    )

    private static let english = SetupWizardCopy(
        languageControlLabel: "Display language",
        japaneseLanguageName: "日本語",
        englishLanguageName: "English",
        sidebarSubtitle: "Setup & Status Center",
        currentStatusTitle: "Current Status",
        headerTitle: "Mimi Setup for Chrome",
        setupSummary: "Follow the numbered steps to get Mimi ready in Chrome. Mimi adds AI live interpretation audio; it does not replace the original speaker's voice.",
        providerPanelTitle: "Translation quality",
        providerPanelExplanation: "Gemini is the free default. GPT Realtime is available only when you deliberately choose higher-quality Japanese and understand its API charges. Mimi never switches to GPT automatically.",
        providerGeminiLabel: "Gemini Live",
        providerGeminiBadge: "Free · Recommended",
        providerGeminiDescription: "Mimi's default, designed to prioritize the free tier.",
        providerOpenAILabel: "GPT Realtime",
        providerOpenAIBadge: "Paid · High quality",
        providerOpenAIDescription: "Uses paid API credits. Choose it when more natural Japanese matters.",
        providerSaving: "Saving provider setting…",
        providerActiveSessionWarning: "Provider switching is disabled during translation. Stop the Chrome extension before changing it.",
        apiKeyTitle: "Prepare Google Translation",
        apiKeyExplanation: "If Google AI Studio is new to you, open AI Studio and sign in with your Google account. If a terms screen appears, check the required boxes and press Continue.",
        accountGuidance: "Then open the API keys page. If a Gemini API key is already listed, use the copy button on that row. If you do not see one, create a free Gemini API key in AI Studio.",
        paidPathGuidance: "If you do not want Google product-improvement use, choose the paid Google Cloud API path instead. Mimi never turns on paid billing by itself. Only if your key has billing enabled, you can add an optional monthly time guide here.",
        guidedKeySteps: "Steps: open AI Studio -> accept required terms if asked -> open the API keys page -> copy the key row -> paste it here",
        replaceKeyGuidance: "To replace the key later, paste the new one here and save. Only this Mac's Keychain entry is updated.",
        trustExplanation: "The key is saved in macOS Keychain, not in the Chrome extension. Do not paste it into chat, GitHub, screenshots, docs, or .env files.",
        apiKeyPlaceholder: "Paste the key you copied from AI Studio",
        openAIStudioFirstRun: "First time: Open AI Studio",
        openAIStudioAPIKeys: "Already set up: API keys page",
        saveAndTest: "Save / replace in Keychain and test",
        googleKeyReady: "Your Google translation key is saved in Keychain",
        changeGoogleKey: "Review or replace the API key",
        keychainHelpTitle: "Find the saved item in Keychain",
        keychainLocationLabel: "Location",
        keychainLocationValue: "Keychain Access → login → All Items (or Passwords)",
        keychainItemNameLabel: "Item name",
        keychainAccountLabel: "Account",
        keychainPasswordsAppNote: "Generic Keychain items may not appear in the macOS Passwords app. Look in Keychain Access instead.",
        openKeychainAccess: "Open Keychain Access",
        copyKeychainItemName: "Copy item name",
        copiedKeychainItemName: "Copied",
        optionalSettingsLabel: "Optional",
        safetyPanelTitle: "API Use Settings",
        safetyToggleTitle: "Use monthly protection for a paid or billing-enabled API key",
        paidKeyLimitFieldLabel: "Optional time guide for a paid key",
        safetyStepperLabel: "Adjust by 5 minutes",
        minutesPerMonth: "min / month",
        saveLimitAndRestart: "Save settings and restart",
        resetUsageCounter: "Reset local usage record",
        safetyExplanation: "With a free Gemini API key, you do not need to worry about a Mimi monthly time limit. Only if your key has billing enabled, you can add an optional time guide here. The automatic stop for forgotten sessions is a separate setting and defaults to 30 minutes. When usage is reset, Mimi keeps a local backup if an old usage file exists.",
        noMonthlyProtectionTitle: "No monthly protection",
        freeKeyNoMonthlyLimit: "Free keys do not need a Mimi monthly cap",
        remainingMinutesPrefix: "Remaining",
        remainingMinutesSuffix: "min",
        usedThisMonthPrefix: "Used this month",
        usedThisMonthSeparator: "of",
        usedThisMonthSuffix: "min",
        helperPanelTitle: "Connect Chrome",
        chromeHelperExplanation: "Mimi automatically installs the helper, starts the server, opens Chrome's extension page, and copies the extension folder path. Follow the numbered Chrome steps below. Setup stays incomplete until it receives a real request from the Chrome extension.",
        prepareChromeConnection: "Start Chrome setup (open page and copy path)",
        prepareChromeConnectionRunning: "Starting Chrome setup...",
        chromeManualConfirmation: "These steps are needed only for the development build. Chrome requires the user to approve adding and enabling the extension. After Chrome Web Store distribution, only Chrome's Add confirmation should remain. If Mimi is already installed, open it from the toolbar once to reconnect.",
        chromeGuideTitle: "Follow these steps in Chrome",
        chromeInstallSteps: [
            "Open Chrome's extensions page and copy the Mimi folder path (the setup button does both)",
            "Turn on Developer mode, choose Load unpacked, and select the Mimi folder",
            "Open Chrome's Extensions menu and pin Mimi",
            "Open Mimi from the toolbar (completion requires a real connection event)"
        ],
        chromePathWillCopy: "Press the setup button above and Mimi will copy the path automatically",
        chromePathCopied: "The Mimi folder path is already copied to the clipboard",
        chromePathCopyFailed: "Automatic copy failed. Select and copy the path shown below",
        chromeReturnToMimi: "Opening Mimi automatically verifies the connection and toolbar pin, then continues without a separate checkbox.",
        chromeConnectionReady: "Verified a real connection from the Chrome extension to Mimi",
        chromePinInstruction: "Open Chrome's Extensions menu (puzzle icon) and pin Mimi. Mimi checks completion automatically.",
        chromePinDetected: "Mimi is pinned to the Chrome toolbar",
        chromeTroubleshootingTitle: "If setup does not work",
        openChromeExtension: "Open Chrome extension setup again",
        installHelper: "Repair helper",
        startServer: "Start server",
        openStatus: "Check status",
        finalPanelTitle: "Start Listening",
        finalStepOne: "Open a public video on YouTube or X Web",
        finalStepTwo: "Open Mimi from the Chrome toolbar",
        finalStepThree: "Choose the language you want to hear, then press Start",
        statusRunning: "Running",
        messageReady: "Ready",
        messageRepoMissing: "Mimi folder was not found",
        messageExtensionPathCopied: "Copied the Chrome extension folder",
        messageExtensionPathCopyFailed: "Could not copy the Chrome extension folder automatically",
        messageSaveLimitSuccess: "Saved API-use settings and restarted the local server",
        messageResetUsageSuccess: "Reset this Mac's usage record",
        messageSaveKeySuccess: "Saved the key and the connection test passed",
        messageHelperSuccess: "Installed and checked the helper",
        messageServerSuccess: "Started the local server",
        messageChromeSetupSuccess: "Verified a real connection from the Chrome extension to Mimi",
        messageChromeSetupOpening: "Opening chrome://extensions/ in Chrome and copying the Mimi folder path. Continue with the steps below when Chrome comes forward.",
        messageChromeInstallPending: "The server is running. Add Mimi in Chrome. Setup remains incomplete until the extension contacts Mimi.",
        messageChromePinRequired: "Verified the Chrome extension connection. Pin Mimi, then open it once from the toolbar.",
        messageChromeSetupFailed: "Mimi did not receive a real connection from the Chrome extension. Add or enable it, then run this step again.",
        messageChromeSetupOpenFailed: "Mimi could not open chrome://extensions/ in Chrome. Open Chrome, go to chrome://extensions/, then use the Mimi folder path below.",
        messageReadyForChrome: "Ready for Chrome",
        messageNeedsAttention: "Needs attention",
        rowGoogleKey: "Google translation key",
        rowChromeConnection: "Connect Chrome",
        rowStartListening: "Start listening",
        stateNotStarted: "Not started",
        stateRunning: "Running",
        stateDone: "Done",
        stateNeedsAttention: "Needs attention",
        stateReady: "Ready for the next step"
    )
}
