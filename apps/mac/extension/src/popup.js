const statusText = document.getElementById("statusText");
const usageText = document.getElementById("usageText");
const costText = document.getElementById("costText");
const sourceText = document.getElementById("sourceText");
const tokenText = document.getElementById("tokenText");
const inputText = document.getElementById("inputText");
const outputText = document.getElementById("outputText");
const errorText = document.getElementById("errorText");
const diagnosticText = document.getElementById("diagnosticText");
const reasonText = document.getElementById("reasonText");
const extensionText = document.getElementById("extensionText");
const transcriptText = document.getElementById("transcriptText");
const uiLanguageButtons = [
  document.getElementById("uiLanguageJa"),
  document.getElementById("uiLanguageEn"),
];
const targetLanguage = document.getElementById("targetLanguage");
const providerButtons = [
  document.getElementById("providerGeminiButton"),
  document.getElementById("providerOpenAIButton"),
];
const startButton = document.getElementById("startButton");
const restartButton = document.getElementById("restartButton");
const stopButton = document.getElementById("stopButton");
const monthlyLimitEnabledInput = document.getElementById("monthlyLimitEnabledInput");
const limitMinutesInput = document.getElementById("limitMinutesInput");
const saveLimitButton = document.getElementById("saveLimitButton");
const autoStopMinutesInput = document.getElementById("autoStopMinutesInput");
const saveAutoStopButton = document.getElementById("saveAutoStopButton");
const resetUsageButton = document.getElementById("resetUsageButton");
const openKeySettingsButton = document.getElementById("openKeySettingsButton");
const copyDiagnosticsButton = document.getElementById("copyDiagnosticsButton");
const originalVolume = document.getElementById("originalVolume");
const translatedVolume = document.getElementById("translatedVolume");
const originalVolumeValue = document.getElementById("originalVolumeValue");
const translatedVolumeValue = document.getElementById("translatedVolumeValue");
const DEFAULT_TARGET_LANGUAGE = "ja";
const DEFAULT_UI_LANGUAGE = "en";
const DEFAULT_AUTO_STOP_MINUTES = 30;
let copyDiagnosticsState = "idle";
let providerSaveInFlight = false;

const COPY = {
  ja: {
    uiLanguageLabel: "表示",
    targetLanguageLabel: "何語で聞く？",
    providerLabel: "翻訳エンジン",
    providerGeminiName: "Gemini Live",
    providerGeminiBadge: "無料・おすすめ",
    providerGeminiDescription: "Mimiの標準設定",
    providerOpenAIName: "GPT Realtime",
    providerOpenAIBadge: "有料・高品質",
    providerOpenAIDescription: "自然さを優先",
    providerHint: "通常は無料のGeminiを使います。GPTはAPI課金を理解して選ぶ場合のみ。自動では切り替わりません。",
    sourceLine: "元の言語は自動判定",
    sessionControlsLabel: "翻訳の操作",
    volumeControlsLabel: "音量",
    originalVolumeLabel: "元の音声",
    translatedVolumeLabel: "翻訳音声",
    advancedSummary: "詳細設定",
    advancedContentLabel: "詳細情報",
    restartButton: "サーバーを再起動して開始",
    settingsGridLabel: "API利用と自動停止",
    monthlyLimitEnabledLabel: "有料キー用の月間保護",
    limitMinutesLabel: "月間保護の時間",
    autoStopLabel: "自動停止タイマー",
    save: "保存",
    resetUsageButton: "使用記録をリセット",
    replaceKey: "APIキーを設定する",
    copyDiagnosticsButton: "診断ログをコピー",
    sourceDetailLabel: "元の言語",
    inputDetailLabel: "送信した音声",
    outputDetailLabel: "翻訳音声",
    errorDetailLabel: "エラー",
    diagnosticDetailLabel: "最近の診断",
    extensionDetailLabel: "拡張機能",
    transcriptDetailLabel: "文字起こし",
    usageDetailLabel: "月間API保護",
    costDetailLabel: "有料枠の目安",
    tokenDetailLabel: "推定トークン",
    advancedNote: "無料キーでは月間API保護なしで使えます。自動停止タイマーは使い忘れ防止です。",
    start: "開始",
    listening: "翻訳中",
    stop: "停止",
    stopTranslation: "翻訳を停止",
    readyToListen: "日本語で聞く準備ができました",
    none: "なし",
    unknown: "確認中",
    autoDetect: "自動判定",
    statusLocalLimit: "月間保護に到達",
    statuses: {
      idle: "準備OK",
      connected: "準備OK",
      connecting: "接続中",
      capturing: "音声取得中",
      error: "エラー",
      reconnecting: "再接続中",
      restarting_server: "ローカルサーバーを再起動中",
      starting_server: "ローカルサーバーを起動中",
      translating: "翻訳中",
    },
    errors: {
      auto_stop_timer: "使い忘れ防止のため、自動停止しました。",
      empty_api_key: "Gemini APIキーを入力してから保存してください。",
      keychain_unavailable: "macOS Keychainに保存できませんでした。Mimi Setupを使ってください。",
      keychain_write_failed: "macOS Keychainに保存できませんでした。Mimi Setupを使ってください。",
      monthly_limit_reached: "有料キー用の月間保護に達しました。使用記録をリセットするか、月間保護の時間を変更してください。",
      missing_gemini_api_key: "Mimi SetupでGemini APIキーを追加してください。",
      missing_openai_api_key: "APIキー設定でMimi専用のOpenAI APIキーを追加してください。",
      openai_lifetime_budget_reached: "OpenAIの累計安全上限（28分・約$0.952）に達したため停止しました。",
      openai_auth_error: "OpenAI APIキーを確認してください。",
      openai_rate_limit: "OpenAIのレート制限に達しました。",
      missing_api_key: "Mimi SetupでGemini APIキーを追加してください。",
      missing_allowed_extension_origin: "このChrome拡張機能用にMimi Setupをもう一度実行してください。",
      quota_or_free_tier_error: "Free Tierの上限、またはGoogle側の混雑により停止しました。",
      auth_error: "Gemini APIキーをMimi Setupで確認してください。",
      capture_active_stream: "Mimi/Chrome がこのタブの音声をすでに取得しています。Mimiを停止してもう一度開始してください。続く場合はタブを再読み込みし、それでも直らない場合はChromeを再起動してください。",
      gemini_project_access_denied: "Google/AI Studio が現在のGemini APIキーまたはプロジェクトを拒否しています。Gemini APIキーを入れ替えるか、AI Studio/Google Cloudのプロジェクト、請求、利用規約の表示を確認してください。プロジェクト自体が拒否されている場合はGoogleサポートに連絡してください。",
      local_server_unavailable: "ローカルサーバーに接続できません。Mimi Setupまたはサーバー再起動を確認してください。",
      native_host_unavailable: "Mimi Setupでローカルヘルパーをインストールしてください。",
    },
    monthlyLimitSet: (enabled, minutes) => enabled ? `月間API保護を${minutes}分/月に設定しました。` : "月間API保護をオフにしました。",
    autoStopSet: (minutes) => `自動停止を${minutes}分に設定しました。`,
    openedKeySettings: "ローカルのAPIキー設定を開きました。",
    copiedDiagnostics: "診断ログをコピーしました。",
    copyDiagnosticsFailed: "診断ログをコピーできませんでした。",
    copyDiagnosticsCopying: "コピー中...",
    copyDiagnosticsCopiedButton: "コピーしました",
    copyDiagnosticsFailedButton: "コピー失敗",
    activeReason: (remaining) => remaining
      ? `翻訳中です。あと${remaining}分で自動停止します。`
      : "翻訳中です。終わったら停止してください。",
    stoppedByTimer: "使い忘れ防止の自動停止で止まりました。",
    stoppedByUser: "停止しました。",
    useSetupReason: "APIキー入れ替えボタンから設定ページを開けます。直接保存できない場合は、表示されるMimi SetupまたはMimi.appの案内に従ってください。",
    addKeyInAdvanced: "詳細設定でGemini APIキーを追加してください。",
    localLimitReason: "有料キー用の月間保護に達しました。使用記録をリセットするか、月間保護の時間を変更してください。",
    usageDisabled: "月間保護なし",
    usage: (remaining, limit) => `残り ${remaining} / ${limit} 分`,
    tokens: (input, output) => `入力 ${input} / 出力 ${output}`,
  },
  en: {
    uiLanguageLabel: "UI language",
    targetLanguageLabel: "Listen in",
    providerLabel: "Translation engine",
    providerGeminiName: "Gemini Live",
    providerGeminiBadge: "Free · Recommended",
    providerGeminiDescription: "Mimi's default",
    providerOpenAIName: "GPT Realtime",
    providerOpenAIBadge: "Paid · High quality",
    providerOpenAIDescription: "Prioritizes natural speech",
    providerHint: "Gemini is the free default. Choose GPT only when you understand its API charges. Mimi never switches automatically.",
    sourceLine: "Auto-detect source",
    sessionControlsLabel: "Session controls",
    volumeControlsLabel: "Volume controls",
    originalVolumeLabel: "Original",
    translatedVolumeLabel: "Translated",
    advancedSummary: "Advanced",
    advancedContentLabel: "Advanced details",
    restartButton: "Restart Server & Start",
    settingsGridLabel: "API usage and auto-stop",
    monthlyLimitEnabledLabel: "Paid-key monthly protection",
    limitMinutesLabel: "Monthly protection time",
    autoStopLabel: "Auto-stop timer",
    save: "Save",
    resetUsageButton: "Reset local usage",
    replaceKey: "Set API keys",
    copyDiagnosticsButton: "Copy diagnostics",
    sourceDetailLabel: "Source",
    inputDetailLabel: "Audio sent",
    outputDetailLabel: "Output",
    errorDetailLabel: "Error",
    diagnosticDetailLabel: "Latest diagnostic",
    extensionDetailLabel: "Extension",
    transcriptDetailLabel: "Transcript",
    usageDetailLabel: "Monthly API protection",
    costDetailLabel: "Paid-tier estimate",
    tokenDetailLabel: "Est. tokens",
    advancedNote: "Free keys can run without Mimi monthly protection. Auto-stop prevents forgotten sessions.",
    start: "Start",
    listening: "Listening",
    stop: "Stop",
    stopTranslation: "Stop Translation",
    readyToListen: "Ready to listen",
    none: "none",
    unknown: "unknown",
    autoDetect: "auto detect",
    statusLocalLimit: "Monthly protection reached",
    statuses: {
      idle: "Ready",
      connected: "Ready",
      connecting: "Connecting",
      capturing: "Capturing",
      error: "Error",
      reconnecting: "Reconnecting",
      restarting_server: "Restarting local server...",
      starting_server: "Starting local server...",
      translating: "Translating",
    },
    errors: {
      auto_stop_timer: "Stopped automatically to prevent forgotten sessions.",
      empty_api_key: "Paste a Gemini API key before replacing it.",
      keychain_unavailable: "Could not save the key to macOS Keychain. Use Mimi Setup.",
      keychain_write_failed: "Could not save the key to macOS Keychain. Use Mimi Setup.",
      monthly_limit_reached: "Paid-key monthly protection reached. Reset usage or increase the monthly protection time below.",
      missing_gemini_api_key: "Run Mimi Setup to add your Gemini API key.",
      missing_openai_api_key: "Add a Mimi-only OpenAI API key in API key settings.",
      openai_lifetime_budget_reached: "Stopped at the OpenAI lifetime safety cap (28 min, about $0.952).",
      openai_auth_error: "Check the OpenAI API key.",
      openai_rate_limit: "OpenAI rate limit reached.",
      missing_api_key: "Run Mimi Setup to add your Gemini API key.",
      missing_allowed_extension_origin: "Run Mimi Setup again for this Chrome extension.",
      quota_or_free_tier_error: "Free Tier limit or Google capacity reached.",
      auth_error: "Check your Gemini API key in Mimi Setup.",
      capture_active_stream: "Mimi/Chrome is already capturing audio for this tab. Stop Mimi and start again. If it continues, reload the tab. If it is still stuck, restart Chrome.",
      gemini_project_access_denied: "Google/AI Studio is rejecting the current Gemini API key or project. Replace the Gemini API key, check AI Studio/Google Cloud project, billing, or terms banners, or contact Google support if the project itself is denied.",
      local_server_unavailable: "Could not connect to the local server. Check Mimi Setup or restart the server.",
      native_host_unavailable: "Run Mimi Setup to install the local helper.",
    },
    monthlyLimitSet: (enabled, minutes) => enabled ? `Monthly API protection set to ${minutes} min/month` : "Monthly API protection turned off",
    autoStopSet: (minutes) => `Auto-stop set to ${minutes} min`,
    openedKeySettings: "Opened local API key settings.",
    copiedDiagnostics: "Copied diagnostics.",
    copyDiagnosticsFailed: "Could not copy diagnostics.",
    copyDiagnosticsCopying: "Copying...",
    copyDiagnosticsCopiedButton: "Copied",
    copyDiagnosticsFailedButton: "Copy failed",
    activeReason: (remaining) => remaining
      ? `Translating. Auto-stop in ${remaining} min.`
      : "Translating. Stop when finished.",
    stoppedByTimer: "Stopped automatically by the auto-stop timer.",
    stoppedByUser: "Stopped.",
    useSetupReason: "Use the replace-key button to open the settings page. If direct saving is unavailable, follow the Mimi Setup or Mimi.app guidance shown there.",
    addKeyInAdvanced: "Add a Gemini API key in Advanced.",
    localLimitReason: "Paid-key monthly protection reached. Reset usage or raise the monthly protection time.",
    usageDisabled: "Monthly protection off",
    usage: (remaining, limit) => `${remaining} / ${limit} min left`,
    tokens: (input, output) => `in ${input} / out ${output}`,
  },
};

let statusTimer = null;
let autoStopMinutes = DEFAULT_AUTO_STOP_MINUTES;
let uiLanguageCode = DEFAULT_UI_LANGUAGE;
let latestState = { status: "idle" };
let limitInputDirty = false;
let limitEnabledDirty = false;
let limitSaveInFlight = false;

for (const button of uiLanguageButtons) {
  button.addEventListener("click", () => saveUiLanguage(button.dataset.uiLanguage));
}
for (const button of providerButtons) {
  button.addEventListener("click", () => saveProvider(button.dataset.provider));
}
startButton.addEventListener("click", () => startSession());
restartButton.addEventListener("click", () => restartAndStartSession());
stopButton.addEventListener("click", () => stopSession());
saveLimitButton.addEventListener("click", () => saveLimit());
saveAutoStopButton.addEventListener("click", () => saveAutoStop());
resetUsageButton.addEventListener("click", () => resetUsage());
openKeySettingsButton.addEventListener("click", () => openKeySettings());
copyDiagnosticsButton.addEventListener("click", () => copyDiagnostics());
limitMinutesInput.addEventListener("input", () => {
  limitInputDirty = true;
});
monthlyLimitEnabledInput.addEventListener("change", () => {
  limitEnabledDirty = true;
  syncMonthlyLimitControls(isActiveStatus(latestState.status));
});
originalVolume.addEventListener("input", () => {
  updateVolumeLabels();
  updateRangeFill(originalVolume);
  sendVolumes();
});
translatedVolume.addEventListener("input", () => {
  updateVolumeLabels();
  updateRangeFill(translatedVolume);
  sendVolumes();
});
targetLanguage.addEventListener("change", () => saveTargetLanguage());
document.addEventListener("DOMContentLoaded", async () => {
  await restoreUiLanguage();
  fillLanguageOptions();
  applyUiLanguage();
  updateVolumeLabels();
  updateRangeFills();
  await restoreTargetLanguage();
  await restoreProvider();
  await restoreAutoStop();
  extensionText.textContent = `chrome-extension://${chrome.runtime.id}`;
  await refreshStatus();
  statusTimer = setInterval(refreshStatus, 500);
});
window.addEventListener("unload", () => {
  if (statusTimer) clearInterval(statusTimer);
});

async function startSession() {
  setStatus({ status: "connecting", error: "none" });
  const response = await sendMessage({
    type: "start",
    originalVolume: Number(originalVolume.value) / 100,
    translatedVolume: Number(translatedVolume.value) / 100,
    targetLanguageCode: selectedTargetLanguageCode(),
    provider: selectedProvider(),
    autoStopMinutes,
  });
  if (!response?.ok) {
    setStatus({ status: "error", error: response?.error || "start_failed" });
  }
}

async function restartAndStartSession() {
  setStatus({ status: "restarting_server", error: "none" });
  const response = await sendMessage({
    type: "restart_start",
    originalVolume: Number(originalVolume.value) / 100,
    translatedVolume: Number(translatedVolume.value) / 100,
    targetLanguageCode: selectedTargetLanguageCode(),
    provider: selectedProvider(),
    autoStopMinutes,
  });
  if (!response?.ok) {
    setStatus({ status: "error", error: response?.error || "restart_failed" });
  }
}

async function stopSession() {
  await sendMessage({ type: "stop" });
  await refreshStatus();
}

async function sendVolumes() {
  await sendMessage({
    type: "set_volumes",
    originalVolume: Number(originalVolume.value) / 100,
    translatedVolume: Number(translatedVolume.value) / 100,
  });
}

async function saveLimit() {
  const monthlyLimitEnabled = Boolean(monthlyLimitEnabledInput.checked);
  const limitMinutes = normalizeMinutes(limitMinutesInput.value, 30, 1, 1440);
  limitMinutesInput.value = String(limitMinutes);
  limitSaveInFlight = true;
  const response = await sendMessage({ type: "set_limit", monthlyLimitEnabled, limitMinutes });
  limitSaveInFlight = false;
  if (!response?.ok) {
    setStatus({ status: "error", error: response?.error || "set_limit_failed" });
    return;
  }
  limitInputDirty = false;
  limitEnabledDirty = false;
  if (response.state) setStatus(response.state);
  reasonText.textContent = t("monthlyLimitSet")(monthlyLimitEnabled, limitMinutes);
}

async function saveAutoStop() {
  autoStopMinutes = normalizeMinutes(autoStopMinutesInput.value, DEFAULT_AUTO_STOP_MINUTES, 1, 120);
  autoStopMinutesInput.value = String(autoStopMinutes);
  await chrome.storage.local.set({ mimiAutoStopMinutes: autoStopMinutes });
  reasonText.textContent = t("autoStopSet")(autoStopMinutes);
}

async function resetUsage() {
  const response = await sendMessage({ type: "reset_usage" });
  if (!response?.ok) {
    setStatus({ status: "error", error: response?.error || "reset_usage_failed" });
    return;
  }
  await refreshStatus();
}

async function openKeySettings() {
  const response = await sendMessage({ type: "open_key_settings" });
  if (!response?.ok) {
    setStatus({ status: "error", error: response?.error || "open_key_settings_failed" });
    return;
  }
  reasonText.textContent = t("openedKeySettings");
}

async function copyDiagnostics() {
  setCopyDiagnosticsState("copying");
  const response = await sendMessage({ type: "copy_diagnostics" });
  if (!response?.ok || !response.text || !navigator.clipboard?.writeText) {
    setCopyDiagnosticsState("failed");
    reasonText.textContent = t("copyDiagnosticsFailed");
    return;
  }
  try {
    await navigator.clipboard.writeText(response.text);
    setCopyDiagnosticsState("copied");
    reasonText.textContent = t("copiedDiagnostics");
  } catch {
    setCopyDiagnosticsState("failed");
    reasonText.textContent = t("copyDiagnosticsFailed");
  }
}

async function refreshStatus() {
  const response = await sendMessage({ type: "get_status" });
  if (response?.ok) setStatus(response.state);
}

function sendMessage(message) {
  return chrome.runtime.sendMessage(message).catch((error) => ({
    ok: false,
    error: error.message,
  }));
}

function setStatus(state = {}) {
  const normalizedDiagnostic = normalizeDiagnosticForDisplay(state.latestDiagnostic);
  const status = state.status || "idle";
  const active = isActiveStatus(status);
  if (active && state.provider) {
    setProviderSelection(state.provider);
  } else if (!active && !providerSaveInFlight && state.preferredProvider) {
    setProviderSelection(state.preferredProvider);
  }
  const error = state.error && state.error !== "none"
    ? state.error
    : state.lastStopReason === "monthly_limit_reached"
      ? "monthly_limit_reached"
      : "none";
  const displayError = normalizeErrorForDisplay(error, normalizedDiagnostic);
  const normalizedStateProvider = normalizeProvider(state.provider) || "gemini";
  const normalizedPreferredProvider = normalizeProvider(state.preferredProvider) || "gemini";
  latestState = {
    ...state,
    provider: normalizedStateProvider,
    preferredProvider: normalizedPreferredProvider,
    error: displayError,
    lastStopReason: normalizeErrorForDisplay(state.lastStopReason, normalizedDiagnostic),
    latestDiagnostic: normalizedDiagnostic,
  };
  document.body.dataset.status = status;
  statusText.textContent = formatStatus(status, displayError);
  errorText.textContent = formatError(displayError);
  diagnosticText.textContent = formatDiagnostic(normalizedDiagnostic, displayError);
  reasonText.textContent = formatReason(latestState);
  transcriptText.textContent = state.transcript || t("none");
  const targetCode = state.targetLanguageCode || selectedTargetLanguageCode();
  sourceText.textContent = t("autoDetect");
  updateUsage(
    state.billing,
    targetCode,
    state.openaiBudget,
    normalizeProvider(isActiveStatus(status) ? state.provider : selectedProvider()) || "gemini",
  );
  inputText.textContent = formatBytes(state.inputBytes || 0);
  outputText.textContent = formatBytes(state.outputBytes || 0);
  startButton.disabled = active || (status !== "idle" && status !== "error");
  restartButton.disabled = active || status === "restarting_server" || status === "starting_server";
  stopButton.disabled = !active;
  targetLanguage.disabled = status !== "idle" && status !== "error";
  for (const button of providerButtons) {
    button.disabled = providerSaveInFlight || active || (status !== "idle" && status !== "error");
  }
  startButton.textContent = active ? t("listening") : t("start");
  stopButton.textContent = active ? t("stopTranslation") : t("stop");
  saveLimitButton.disabled = active;
  saveAutoStopButton.disabled = active;
  resetUsageButton.disabled = active;
  copyDiagnosticsButton.disabled = active || copyDiagnosticsState === "copying";
  openKeySettingsButton.disabled = active;
  openKeySettingsButton.textContent = t("replaceKey");
  if (state.billing && !limitEnabledDirty && !limitSaveInFlight) {
    monthlyLimitEnabledInput.checked = state.billing.monthlyLimitEnabled === true;
  }
  syncMonthlyLimitControls(active);
  autoStopMinutesInput.disabled = active;
  if (state.billing?.limitSeconds && !limitInputDirty && !limitSaveInFlight && document.activeElement !== limitMinutesInput) {
    limitMinutesInput.value = String(Math.round(state.billing.limitSeconds / 60));
  }
}

function syncMonthlyLimitControls(active) {
  monthlyLimitEnabledInput.disabled = active;
  limitMinutesInput.disabled = active || !monthlyLimitEnabledInput.checked;
}

function setCopyDiagnosticsState(state) {
  copyDiagnosticsState = state;
  copyDiagnosticsButton.dataset.copyState = state;
  copyDiagnosticsButton.setAttribute("aria-live", "polite");
  copyDiagnosticsButton.setAttribute("aria-busy", state === "copying" ? "true" : "false");
  const labelKey = {
    idle: "copyDiagnosticsButton",
    copying: "copyDiagnosticsCopying",
    copied: "copyDiagnosticsCopiedButton",
    failed: "copyDiagnosticsFailedButton",
  }[state] || "copyDiagnosticsButton";
  copyDiagnosticsButton.textContent = t(labelKey);
  copyDiagnosticsButton.disabled = state === "copying" || isActiveStatus(latestState.status);
}

function updateUsage(billing, targetCode, openaiBudget, provider) {
  if (provider === "openai") {
    const remaining = formatMinutes(openaiBudget?.remainingSeconds || 0);
    const limit = formatMinutes(openaiBudget?.limitSeconds || 1680);
    usageText.textContent = t("usage")(remaining, limit);
    costText.textContent = formatCost(openaiBudget?.usedUsd || 0, 0, targetCode);
    tokenText.textContent = t("none");
    return;
  }
  if (!billing || billing.monthlyLimitEnabled !== true) {
    usageText.textContent = t("usageDisabled");
    costText.textContent = formatCost(0, 0, targetCode);
    tokenText.textContent = t("tokens")("0", "0");
    return;
  }
  const remaining = formatMinutes(billing.remainingSeconds || 0);
  const limit = formatMinutes(billing.limitSeconds || 0);
  usageText.textContent = t("usage")(remaining, limit);
  costText.textContent = formatCost(billing.cost?.totalUsd || 0, billing.cost?.totalJpy || 0, targetCode);
  const usage = billing.displayUsage || billing.estimatedUsage || billing.usage || {};
  tokenText.textContent = t("tokens")(formatCount(usage.inputTokens || 0), formatCount(usage.outputTokens || 0));
}

function isProjectAccessDeniedDetail(value) {
  const text = String(value || "").toLowerCase();
  return text.includes("project has been denied access")
    || text.includes("permission_denied")
    || text.includes("access restricted")
    || /\b403\b/.test(text);
}

function normalizeDiagnosticForDisplay(diagnostic) {
  if (!diagnostic || typeof diagnostic !== "object") return null;
  const code = isProjectAccessDeniedDetail(diagnostic.detail)
    ? "gemini_project_access_denied"
    : String(diagnostic.code || "");
  return {
    ...diagnostic,
    code,
    detail: code === "gemini_project_access_denied"
      ? t("errors").gemini_project_access_denied
      : diagnostic.detail,
  };
}

function normalizeErrorForDisplay(error, diagnostic) {
  const code = error || "none";
  if (code === "gemini_project_access_denied") return "gemini_project_access_denied";
  if (code === "network_error" && (
    diagnostic?.code === "gemini_project_access_denied" || isProjectAccessDeniedDetail(diagnostic?.detail)
  )) {
    return "gemini_project_access_denied";
  }
  return code;
}

function formatStatus(status, error = "none") {
  if (error === "monthly_limit_reached") return t("statusLocalLimit");
  return t("statuses")[status] || status;
}

function formatError(error) {
  if (!error || error === "none") return t("none");
  if (error.startsWith("missing_gemini_api_key")) return t("errors").missing_gemini_api_key;
  if (error.startsWith("missing_allowed_extension_origin")) return t("errors").missing_allowed_extension_origin;
  if (error.startsWith("quota_or_free_tier_error")) return t("errors").quota_or_free_tier_error;
  if (error.startsWith("auth_error")) return t("errors").auth_error;
  if (error.startsWith("native_host_unavailable")) return t("errors").native_host_unavailable;
  const code = error.split(":")[0];
  return t("errors")[error] || t("errors")[code] || code;
}

function formatDiagnostic(diagnostic, error) {
  if (diagnostic?.detail) return diagnostic.detail;
  if (error && error !== "none") return formatError(error);
  return t("none");
}

function formatReason(state = {}) {
  const status = state.status || "idle";
  const error = state.error || "none";
  if (isActiveStatus(status)) {
    return t("activeReason")(remainingAutoStopMinutes(state.autoStopAtMs));
  }
  if (error && error !== "none") return formatError(error);
  if (state.lastStopReason === "monthly_limit_reached") return formatError("monthly_limit_reached");
  if (state.lastStopReason === "auto_stop_timer") return t("stoppedByTimer");
  if (state.lastStopReason === "user_stopped") return t("stoppedByUser");
  if (state.geminiApiKey?.canReplace === false) return t("useSetupReason");
  if (state.geminiApiKey?.configured === false) return t("addKeyInAdvanced");
  if (state.billing?.monthlyLimitEnabled === true && state.billing?.remainingSeconds <= 0) return t("localLimitReason");
  return t("readyToListen");
}

function remainingAutoStopMinutes(autoStopAtMs) {
  const value = Number(autoStopAtMs || 0);
  if (!value) return "";
  return String(Math.max(1, Math.ceil((value - Date.now()) / 60000)));
}

function applyUiLanguage() {
  document.documentElement.lang = uiLanguageCode;
  setText("uiLanguageLabel", "uiLanguageLabel");
  for (const button of uiLanguageButtons) {
    button.setAttribute("aria-pressed", button.dataset.uiLanguage === uiLanguageCode ? "true" : "false");
  }
  setText("targetLanguageLabel", "targetLanguageLabel");
  setText("providerLabel", "providerLabel");
  setText("providerGeminiName", "providerGeminiName");
  setText("providerGeminiBadge", "providerGeminiBadge");
  setText("providerGeminiDescription", "providerGeminiDescription");
  setText("providerOpenAIName", "providerOpenAIName");
  setText("providerOpenAIBadge", "providerOpenAIBadge");
  setText("providerOpenAIDescription", "providerOpenAIDescription");
  setText("providerHint", "providerHint");
  setText("sourceLine", "sourceLine");
  setText("originalVolumeLabel", "originalVolumeLabel");
  setText("translatedVolumeLabel", "translatedVolumeLabel");
  setText("advancedSummary", "advancedSummary");
  setText("monthlyLimitEnabledLabel", "monthlyLimitEnabledLabel");
  setText("limitMinutesLabel", "limitMinutesLabel");
  setText("autoStopLabel", "autoStopLabel");
  setText("resetUsageButton", "resetUsageButton");
  setCopyDiagnosticsState(copyDiagnosticsState);
  setText("sourceDetailLabel", "sourceDetailLabel");
  setText("inputDetailLabel", "inputDetailLabel");
  setText("outputDetailLabel", "outputDetailLabel");
  setText("errorDetailLabel", "errorDetailLabel");
  setText("diagnosticDetailLabel", "diagnosticDetailLabel");
  setText("extensionDetailLabel", "extensionDetailLabel");
  setText("transcriptDetailLabel", "transcriptDetailLabel");
  setText("usageDetailLabel", "usageDetailLabel");
  setText("costDetailLabel", "costDetailLabel");
  setText("tokenDetailLabel", "tokenDetailLabel");
  setText("advancedNote", "advancedNote");
  document.getElementById("sessionControls").setAttribute("aria-label", t("sessionControlsLabel"));
  document.getElementById("volumeControls").setAttribute("aria-label", t("volumeControlsLabel"));
  document.getElementById("advancedContent").setAttribute("aria-label", t("advancedContentLabel"));
  document.getElementById("settingsGrid").setAttribute("aria-label", t("settingsGridLabel"));
  restartButton.textContent = t("restartButton");
  saveLimitButton.textContent = t("save");
  saveAutoStopButton.textContent = t("save");
  if (!extensionText.textContent) extensionText.textContent = t("unknown");
  setStatus(latestState);
}

function setText(id, key) {
  document.getElementById(id).textContent = t(key);
}

function t(key) {
  return COPY[uiLanguageCode]?.[key] ?? COPY[DEFAULT_UI_LANGUAGE][key];
}

function fillLanguageOptions() {
  const languages = window.MIMI_TARGET_LANGUAGES || [];
  const selected = targetLanguage.value || DEFAULT_TARGET_LANGUAGE;
  targetLanguage.textContent = "";
  for (const language of languages) {
    const option = document.createElement("option");
    option.value = language.code;
    option.textContent = `${language.flag} ${languageDisplayName(language)}`;
    targetLanguage.append(option);
  }
  targetLanguage.value = selected;
  if (!targetLanguage.value) targetLanguage.value = DEFAULT_TARGET_LANGUAGE;
}

function languageDisplayName(language) {
  const localName = language.names?.[uiLanguageCode];
  if (localName) return localName;
  try {
    const displayNames = new Intl.DisplayNames([uiLanguageCode], { type: "language" });
    return displayNames.of(language.code) || language.name;
  } catch {
    return language.name;
  }
}

async function restoreUiLanguage() {
  const stored = await chrome.storage.local.get("mimiUiLanguageCode");
  uiLanguageCode = normalizeUiLanguage(stored.mimiUiLanguageCode);
}

async function saveUiLanguage(value) {
  uiLanguageCode = normalizeUiLanguage(value);
  await chrome.storage.local.set({ mimiUiLanguageCode: uiLanguageCode });
  fillLanguageOptions();
  applyUiLanguage();
}

function normalizeUiLanguage(value) {
  return value === "ja" ? "ja" : DEFAULT_UI_LANGUAGE;
}

async function restoreTargetLanguage() {
  const stored = await chrome.storage.local.get("mimiTargetLanguageCode");
  targetLanguage.value = stored.mimiTargetLanguageCode || DEFAULT_TARGET_LANGUAGE;
  if (!targetLanguage.value) targetLanguage.value = DEFAULT_TARGET_LANGUAGE;
}

async function restoreProvider() {
  const stored = await chrome.storage.local.get("mimiTranslationProvider");
  const raw = stored.mimiTranslationProvider;
  const provider = normalizeProvider(raw);
  if (provider) {
    setProviderSelection(provider);
    const rawProvider = raw === undefined || raw === null ? "" : String(raw).trim().toLowerCase();
    if (rawProvider && rawProvider !== provider) {
      await chrome.storage.local.set({ mimiTranslationProvider: provider });
    }
  }
}

async function restoreAutoStop() {
  const stored = await chrome.storage.local.get("mimiAutoStopMinutes");
  autoStopMinutes = normalizeMinutes(stored.mimiAutoStopMinutes, DEFAULT_AUTO_STOP_MINUTES, 1, 120);
  autoStopMinutesInput.value = String(autoStopMinutes);
}

async function saveTargetLanguage() {
  await chrome.storage.local.set({ mimiTargetLanguageCode: selectedTargetLanguageCode() });
  await sendMessage({ type: "set_target_language", targetLanguageCode: selectedTargetLanguageCode() });
  await refreshStatus();
}

async function saveProvider(value) {
  if (providerSaveInFlight) return;
  const previousProvider = selectedProvider();
  const provider = normalizeProvider(value);
  if (!provider) {
    setStatus({ status: "error", error: "unsupported_provider" });
    return;
  }
  providerSaveInFlight = true;
  setProviderSelection(provider);
  for (const button of providerButtons) button.disabled = true;
  try {
    const response = await sendMessage({ type: "set_provider", provider });
    if (!response?.ok) {
      setProviderSelection(previousProvider);
      setStatus({ status: "error", error: response?.error || "set_provider_failed" });
      return;
    }
    let canonicalValue;
    if (Object.prototype.hasOwnProperty.call(response, "preferredProvider")) {
      canonicalValue = response.preferredProvider;
    } else if (response.state && Object.prototype.hasOwnProperty.call(response.state, "preferredProvider")) {
      canonicalValue = response.state.preferredProvider;
    }
    const canonicalProvider = canonicalValue === undefined || canonicalValue === null || String(canonicalValue).trim() === ""
      ? ""
      : normalizeProvider(canonicalValue);
    if (!canonicalProvider) {
      setProviderSelection(previousProvider);
      setStatus({ status: "error", error: "unsupported_provider" });
      return;
    }
    await chrome.storage.local.set({ mimiTranslationProvider: canonicalProvider });
    setProviderSelection(canonicalProvider);
    if (response.state) {
      setStatus(response.state);
      setProviderSelection(canonicalProvider);
    } else {
      await refreshStatus();
    }
  } catch (error) {
    setProviderSelection(previousProvider);
    setStatus({ status: "error", error: error?.message || "set_provider_failed" });
  } finally {
    providerSaveInFlight = false;
    const status = latestState.status || "idle";
    const active = isActiveStatus(status);
    for (const button of providerButtons) {
      button.disabled = active || (status !== "idle" && status !== "error");
    }
  }
}

function selectedTargetLanguageCode() {
  return targetLanguage.value || DEFAULT_TARGET_LANGUAGE;
}

function selectedProvider() {
  const selected = providerButtons.find((button) => button.getAttribute("aria-pressed") === "true");
  return normalizeProvider(selected?.dataset.provider);
}

function setProviderSelection(value) {
  const provider = normalizeProvider(value);
  if (!provider) return false;
  for (const button of providerButtons) {
    const selected = button.dataset.provider === provider;
    button.setAttribute("aria-checked", selected ? "true" : "false");
    button.setAttribute("aria-pressed", selected ? "true" : "false");
  }
  return true;
}

function normalizeProvider(value) {
  if (value === undefined || value === null || String(value).trim() === "") return "gemini";
  const provider = String(value).trim().toLowerCase();
  if (provider === "xai" || provider === "grok") return "gemini";
  return ["gemini", "openai"].includes(provider) ? provider : "";
}

function updateVolumeLabels() {
  originalVolumeValue.textContent = `${Number(originalVolume.value || 0)}%`;
  translatedVolumeValue.textContent = `${Number(translatedVolume.value || 0)}%`;
}

function updateRangeFills() {
  updateRangeFill(originalVolume);
  updateRangeFill(translatedVolume);
}

function updateRangeFill(input) {
  const min = Number(input.min || 0);
  const max = Number(input.max || 100);
  const value = Number(input.value || 0);
  const percent = max === min ? 0 : ((value - min) / (max - min)) * 100;
  const clamped = Math.round(Math.max(0, Math.min(100, percent)));
  input.style.setProperty("--range-value", `${clamped}%`);
}

function formatCost(totalUsd, totalJpy, targetCode) {
  const usd = formatUsd(totalUsd);
  return targetCode === "ja" ? `${usd} / ${formatJpy(totalJpy)}` : usd;
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  return `${Math.round(bytes / 1024)} KB`;
}

function formatMinutes(seconds) {
  const minutes = seconds / 60;
  return minutes >= 10 ? String(Math.round(minutes)) : minutes.toFixed(1);
}

function formatUsd(value) {
  return `$${value.toFixed(value < 0.01 ? 4 : 2)}`;
}

function formatJpy(value) {
  return `¥${Math.round(value).toLocaleString("ja-JP")}`;
}

function formatCount(value) {
  return Math.round(value).toLocaleString("en-US");
}

function normalizeMinutes(value, fallback, min, max) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return fallback;
  return Math.round(Math.min(max, Math.max(min, number)));
}

function isActiveStatus(status) {
  return ["connecting", "capturing", "translating", "reconnecting", "starting_server", "restarting_server"].includes(status);
}
