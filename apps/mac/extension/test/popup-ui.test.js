const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const HELPER_DOWNLOAD_URL = "https://github.com/AkiGarage/mimi/releases/download/v0.1.2/Mimi-0.1.2-macOS-notarized.zip";

test("popup exposes the signed Mimi Setup download in a new tab", async () => {
  const htmlPath = path.resolve(__dirname, "..", "src", "popup.html");
  const html = fs.readFileSync(htmlPath, "utf8");
  assert.match(html, new RegExp(`id="downloadHelperLink"[^>]+href="${HELPER_DOWNLOAD_URL.replaceAll(".", "\\.")}"`));
  assert.match(html, /id="downloadHelperLink"[^>]+target="_blank"[^>]+rel="noreferrer"/);

  const english = loadPopupHarness();
  await english.dispatchDomReady();
  assert.equal(english.elements.downloadHelperLink.textContent, "Download Mimi Setup");

  const japanese = loadJapanesePopupHarness();
  await japanese.dispatchDomReady();
  assert.equal(japanese.elements.downloadHelperLink.textContent, "Mimi Setupをダウンロード");
});

test("popup keeps visible volume percentage labels in sync with sliders", async () => {
  const harness = loadPopupHarness();
  await harness.dispatchDomReady();

  assert.equal(harness.elements.originalVolumeValue.textContent, "35%");
  assert.equal(harness.elements.translatedVolumeValue.textContent, "85%");
  assert.equal(harness.elements.originalVolume.style.values["--range-value"], "35%");
  assert.equal(harness.elements.translatedVolume.style.values["--range-value"], "85%");

  harness.elements.originalVolume.value = "42";
  harness.elements.translatedVolume.value = "7";
  await harness.elements.originalVolume.listeners.input();
  await harness.elements.translatedVolume.listeners.input();

  assert.equal(harness.elements.originalVolumeValue.textContent, "42%");
  assert.equal(harness.elements.translatedVolumeValue.textContent, "7%");
  assert.equal(harness.elements.originalVolume.style.values["--range-value"], "42%");
  assert.equal(harness.elements.translatedVolume.style.values["--range-value"], "7%");
  const lastMessage = harness.runtimeMessages.at(-1);
  assert.equal(lastMessage.type, "set_volumes");
  assert.equal(lastMessage.originalVolume, 0.42);
  assert.equal(lastMessage.translatedVolume, 0.07);
});

test("popup keeps cost and token details out of the default panel", () => {
  const htmlPath = path.resolve(__dirname, "..", "src", "popup.html");
  const cssPath = path.resolve(__dirname, "..", "src", "popup.css");
  const html = fs.readFileSync(htmlPath, "utf8");
  const css = fs.readFileSync(cssPath, "utf8");
  const defaultPanel = html.slice(0, html.indexOf("<details"));

  assert.match(defaultPanel, /UI language/);
  assert.match(defaultPanel, /日/);
  assert.match(defaultPanel, /En/);
  assert.match(defaultPanel, /Listen in/);
  assert.match(defaultPanel, /Auto-detect source/);
  assert.doesNotMatch(defaultPanel, /cost/i);
  assert.doesNotMatch(defaultPanel, /token/i);
  assert.doesNotMatch(defaultPanel, /billing/i);
  assert.doesNotMatch(defaultPanel, /Audio sent/i);
  assert.doesNotMatch(defaultPanel, /Extension/i);
  assert.match(html, /Paid-tier estimate/);
  assert.match(html, />En</);
  assert.match(defaultPanel, /providerGeminiButton/);
  assert.match(defaultPanel, /providerOpenAIButton/);
  assert.doesNotMatch(defaultPanel, /providerXaiButton|providerXaiName|providerXaiDescription/);
  assert.match(defaultPanel, /Gemini Live/);
  assert.match(defaultPanel, /GPT Realtime/);
  assert.doesNotMatch(defaultPanel, /Grok Voice|xAI|Grok/);
  assert.match(defaultPanel, /無料・おすすめ|Free · Recommended/);
  assert.match(defaultPanel, /有料|Paid/);
  assert.match(defaultPanel, /無料・おすすめ/);
  assert.match(defaultPanel, /有料・高品質/);
  assert.match(defaultPanel, /自動では切り替わりません/);
  assert.match(css, /\.provider-segments\s*\{[^}]*grid-template-columns:\s*repeat\(2,/s);
  assert.doesNotMatch(css, /\.provider-segments\s*\{[^}]*repeat\(3,/s);
});

test("popup maps setup and safety-limit errors to user-facing text", async () => {
  const harness = loadJapanesePopupHarness();
  await harness.dispatchDomReady();

  harness.context.setStatus({ status: "error", error: "missing_gemini_api_key:run setup" });
  assert.equal(harness.elements.statusText.textContent, "エラー");
  assert.equal(harness.elements.errorText.textContent, "Mimi SetupでGemini APIキーを追加してください。");

  harness.context.setStatus({ status: "error", error: "monthly_limit_reached" });
  assert.equal(harness.elements.statusText.textContent, "月間保護に到達");
  assert.match(harness.elements.errorText.textContent, /有料キー用の月間保護に達しました/);
  assert.match(harness.elements.errorText.textContent, /使用記録をリセット/);

  harness.context.setStatus({ status: "idle", error: "none", lastStopReason: "monthly_limit_reached" });
  assert.equal(harness.elements.statusText.textContent, "月間保護に到達");
  assert.match(harness.elements.reasonText.textContent, /有料キー用の月間保護に達しました/);
  assert.match(harness.elements.reasonText.textContent, /使用記録をリセット/);

  harness.context.setStatus({ status: "error", error: "local_server_unavailable" });
  assert.match(harness.elements.errorText.textContent, /ローカルサーバーに接続できません/);
  assert.doesNotMatch(harness.elements.errorText.textContent, /すでに取得しています/);

  harness.context.setStatus({ status: "error", error: "gemini_project_access_denied" });
  assert.match(harness.elements.errorText.textContent, /Google\/AI Studio/);
  assert.match(harness.elements.errorText.textContent, /APIキー/);
  assert.match(harness.elements.errorText.textContent, /Googleサポート/);
  assert.doesNotMatch(harness.elements.errorText.textContent, /network/i);

  harness.context.setStatus({
    status: "error",
    error: "network_error",
    lastStopReason: "network_error",
    latestDiagnostic: {
      timestamp: "2026-07-09T05:40:59.644Z",
      stage: "gemini",
      code: "network_error",
      detail: "close_1008:Your project has been denied access. Please contact support.",
    },
  });
  assert.match(harness.elements.errorText.textContent, /Google\/AI Studio/);
  assert.match(harness.elements.reasonText.textContent, /Google\/AI Studio/);
  assert.match(harness.elements.diagnosticText.textContent, /Gemini APIキー/);
  assert.doesNotMatch(harness.elements.errorText.textContent, /network/i);
  assert.doesNotMatch(harness.elements.diagnosticText.textContent, /Your project has been denied access|close_1008/i);

  harness.context.setStatus({
    status: "idle",
    error: "none",
    lastStopReason: "",
    latestDiagnostic: {
      timestamp: "2026-07-09T05:40:59.644Z",
      stage: "gemini",
      code: "gemini_project_access_denied",
      detail: "Google/AI Studio が現在のGemini APIキーまたはプロジェクトを拒否しています。",
    },
  });
  assert.equal(harness.elements.errorText.textContent, "なし");
  assert.doesNotMatch(harness.elements.reasonText.textContent, /Google\/AI Studio|APIキー/);
  assert.match(harness.elements.diagnosticText.textContent, /Gemini APIキー/);
});

test("popup shows actionable Japanese active-stream diagnostics in Advanced", async () => {
  const harness = loadJapanesePopupHarness();
  await harness.dispatchDomReady();

  harness.context.setStatus({
    status: "error",
    error: "capture_active_stream",
    latestDiagnostic: {
      code: "capture_active_stream",
      stage: "capture_stream",
      detail: "Mimi/Chrome がこのタブの音声をすでに取得しています。Mimiを停止してもう一度開始してください。続く場合はタブを再読み込みし、それでも直らない場合はChromeを再起動してください。",
    },
  });

  assert.equal(harness.elements.statusText.textContent, "エラー");
  assert.match(harness.elements.errorText.textContent, /すでに取得しています/);
  assert.match(harness.elements.reasonText.textContent, /タブを再読み込み/);
  assert.match(harness.elements.diagnosticText.textContent, /Chromeを再起動/);
  assert.doesNotMatch(harness.elements.diagnosticText.textContent, /Can't capture a tab with an active stream/);
});

test("popup makes Stop the only clear action while translating", async () => {
  const harness = loadJapanesePopupHarness();
  await harness.dispatchDomReady();

  harness.context.setStatus({ status: "translating", autoStopAtMs: Date.now() + 30 * 60 * 1000 });

  assert.equal(harness.elements.startButton.disabled, true);
  assert.equal(harness.elements.restartButton.disabled, true);
  assert.equal(harness.elements.stopButton.disabled, false);
  assert.equal(harness.elements.stopButton.textContent, "翻訳を停止");
  assert.match(harness.elements.reasonText.textContent, /あと30分で自動停止/);
});

test("popup migrates a stale cached xAI provider to Gemini", async () => {
  const harness = loadPopupHarness({
    storageGet: { mimiTranslationProvider: "xai" },
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle", preferredProvider: "xai" } };
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "false");
  assert.equal(harness.storageSet.mimiTranslationProvider, "gemini");
  await harness.elements.startButton.listeners.click();
  const startMessage = harness.runtimeMessages.find((message) => message.type === "start");
  assert.equal(startMessage.provider, "gemini");
});

test("popup uses the active session provider for usage while cached preference differs", async () => {
  const harness = loadPopupHarness({
    storageGet: { mimiTranslationProvider: "gemini" },
  });
  await harness.dispatchDomReady();

  harness.context.setStatus({
    status: "translating",
    provider: "gemini",
    preferredProvider: "gemini",
    billing: { monthlyLimitEnabled: true, remainingSeconds: 0, limitSeconds: 1800 },
  });

  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "false");
  assert.equal(harness.elements.usageText.textContent, "0.0 / 30 min left");
});

test("popup restores a cached provider and sends an explicit provider on start", async () => {
  const harness = loadPopupHarness({
    storageGet: { mimiTranslationProvider: "openai" },
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle" } };
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "true");
  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "false");

  await harness.elements.startButton.listeners.click();
  const startMessage = harness.runtimeMessages.find((message) => message.type === "start");
  assert.equal(startMessage.provider, "openai");
});

test("popup rolls back provider selection and does not cache when canonical provider save fails", async () => {
  const harness = loadPopupHarness({
    storageGet: { mimiTranslationProvider: "gemini" },
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle", preferredProvider: "gemini" } };
      if (message.type === "set_provider") return { ok: false, error: "local_server_unavailable" };
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  await harness.elements.providerOpenAIButton.listeners.click();
  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "false");
  assert.equal(harness.storageSet.mimiTranslationProvider, undefined);
  assert.match(harness.elements.errorText.textContent, /Could not connect to the local server/);
});

test("popup rejects an explicit unknown provider instead of defaulting to Gemini", async () => {
  const harness = loadPopupHarness({
    storageGet: { mimiTranslationProvider: "unknown" },
  });
  await harness.dispatchDomReady();

  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");
  await harness.context.saveProvider("unknown");
  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "false");
  assert.equal(harness.runtimeMessages.some((message) => message.type === "set_provider"), false);
  assert.equal(harness.storageSet.mimiTranslationProvider, undefined);
  assert.equal(harness.elements.errorText.textContent, "unsupported_provider");
});

test("popup persists provider through the worker and keeps buttons accessible and locked during a session", async () => {
  const harness = loadPopupHarness({
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle", preferredProvider: "gemini" } };
      if (message.type === "set_provider") return { ok: true, preferredProvider: message.provider, state: { status: "idle", preferredProvider: message.provider } };
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  assert.equal(harness.elements.providerGeminiButton.attributes.role, "radio");
  assert.equal(harness.elements.providerOpenAIButton.attributes.role, "radio");
  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");

  await harness.elements.providerOpenAIButton.listeners.click();
  assert.equal(harness.storageSet.mimiTranslationProvider, "openai");
  assert.equal(harness.runtimeMessages.at(-1).type, "set_provider");
  assert.equal(harness.runtimeMessages.at(-1).provider, "openai");
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-pressed"], "true");

  harness.context.setStatus({ status: "translating", provider: "openai", preferredProvider: "gemini" });
  assert.equal(harness.elements.providerGeminiButton.disabled, true);
  assert.equal(harness.elements.providerOpenAIButton.disabled, true);
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "true");
});

test("popup keeps the clicked provider visibly selected while the canonical save is pending", async () => {
  const providerSave = deferred();
  const harness = loadPopupHarness({
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle", preferredProvider: "gemini" } };
      if (message.type === "set_provider") return providerSave.promise;
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  const click = harness.elements.providerOpenAIButton.listeners.click();
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "true");

  harness.context.setStatus({ status: "idle", preferredProvider: "gemini" });
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "true");
  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "false");

  providerSave.resolve({
    ok: true,
    preferredProvider: "openai",
    state: { status: "idle", preferredProvider: "openai" },
  });
  await click;
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "true");
});

test("popup adopts the server preferred provider only while idle", async () => {
  const harness = loadPopupHarness({
    storageGet: { mimiTranslationProvider: "openai" },
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle", preferredProvider: "gemini" } };
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();
  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");

  harness.context.setStatus({ status: "translating", provider: "gemini", preferredProvider: "openai" });
  assert.equal(harness.elements.providerGeminiButton.attributes["aria-checked"], "true");
  assert.equal(harness.elements.providerOpenAIButton.attributes["aria-checked"], "false");
});

test("popup saves and immediately shows the updated paid-key monthly protection", async () => {
  const harness = loadJapanesePopupHarness({
    sendMessage: async (message) => {
      if (message.type === "get_status") {
        return { ok: true, state: { status: "idle", billing: { monthlyLimitEnabled: false, remainingSeconds: null, limitSeconds: 1800 } } };
      }
      if (message.type === "set_limit") {
        return { ok: true, state: { status: "idle", billing: { monthlyLimitEnabled: true, remainingSeconds: 2700, limitSeconds: 2700 } } };
      }
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();
  assert.equal(harness.elements.usageText.textContent, "月間保護なし");
  assert.equal(harness.elements.limitMinutesInput.disabled, true);

  harness.elements.monthlyLimitEnabledInput.checked = true;
  await harness.elements.monthlyLimitEnabledInput.listeners.change();
  harness.elements.limitMinutesInput.value = "45";
  await harness.elements.saveLimitButton.listeners.click();
  assert.equal(harness.runtimeMessages.at(-1).type, "set_limit");
  assert.equal(harness.runtimeMessages.at(-1).monthlyLimitEnabled, true);
  assert.equal(harness.runtimeMessages.at(-1).limitMinutes, 45);
  assert.equal(harness.elements.limitMinutesInput.value, "45");
  assert.equal(harness.elements.usageText.textContent, "残り 45 / 45 分");
});

test("popup does not overwrite the paid-key monthly protection time while the user is typing", async () => {
  const harness = loadPopupHarness();
  await harness.dispatchDomReady();

  harness.document.activeElement = harness.elements.limitMinutesInput;
  harness.elements.limitMinutesInput.value = "4";
  harness.elements.limitMinutesInput.listeners.input();
  harness.context.setStatus({
    status: "idle",
    billing: { monthlyLimitEnabled: true, remainingSeconds: 3600, limitSeconds: 3600 },
  });

  assert.equal(harness.elements.limitMinutesInput.value, "4");

  harness.document.activeElement = harness.elements.startButton;
  harness.context.setStatus({
    status: "idle",
    billing: { monthlyLimitEnabled: true, remainingSeconds: 3600, limitSeconds: 3600 },
  });

  assert.equal(harness.elements.limitMinutesInput.value, "4");
});

test("popup saves a dirty paid-key monthly protection limit after blur-time status refresh", async () => {
  const harness = loadJapanesePopupHarness({
    sendMessage: async (message) => {
      if (message.type === "get_status") {
        return { ok: true, state: { status: "idle", billing: { monthlyLimitEnabled: false, remainingSeconds: null, limitSeconds: 3600 } } };
      }
      if (message.type === "set_limit") {
        return {
          ok: true,
          state: {
            status: "idle",
            billing: { monthlyLimitEnabled: true, remainingSeconds: message.limitMinutes * 60, limitSeconds: message.limitMinutes * 60 },
          },
        };
      }
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();
  assert.equal(harness.elements.usageText.textContent, "月間保護なし");
  assert.equal(harness.elements.limitMinutesInput.disabled, true);

  harness.elements.monthlyLimitEnabledInput.checked = true;
  await harness.elements.monthlyLimitEnabledInput.listeners.change();
  harness.elements.limitMinutesInput.value = "45";
  harness.elements.limitMinutesInput.listeners.input();
  harness.document.activeElement = harness.elements.saveLimitButton;
  harness.context.setStatus({
    status: "idle",
    billing: { monthlyLimitEnabled: true, remainingSeconds: 3600, limitSeconds: 3600 },
  });

  await harness.elements.saveLimitButton.listeners.click();

  assert.equal(harness.runtimeMessages.at(-1).type, "set_limit");
  assert.equal(harness.runtimeMessages.at(-1).monthlyLimitEnabled, true);
  assert.equal(harness.runtimeMessages.at(-1).limitMinutes, 45);
  assert.equal(harness.elements.limitMinutesInput.value, "45");
  assert.equal(harness.elements.usageText.textContent, "残り 45 / 45 分");
});

test("popup sends safety setting actions and opens key settings without persisting API keys", async () => {
  const harness = loadJapanesePopupHarness();
  await harness.dispatchDomReady();

  harness.elements.autoStopMinutesInput.value = "20";
  await harness.elements.saveAutoStopButton.listeners.click();
  assert.equal(harness.storageSet.mimiAutoStopMinutes, 20);

  harness.context.setStatus({
    status: "idle",
    geminiApiKey: { configured: true, canReplace: true },
  });
  assert.equal(harness.elements.openKeySettingsButton.disabled, false);
  assert.equal(harness.elements.openKeySettingsButton.textContent, "APIキーを設定する");

  await harness.elements.openKeySettingsButton.listeners.click();
  assert.equal(harness.runtimeMessages.at(-1).type, "open_key_settings");
  assert.equal(harness.storageSet.apiKey, undefined);
});

test("popup copies safe diagnostics and shows user feedback", async () => {
  const copyResponse = deferred();
  const harness = loadJapanesePopupHarness({
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle" } };
      if (message.type === "copy_diagnostics") {
        return copyResponse.promise;
      }
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  const click = harness.elements.copyDiagnosticsButton.listeners.click();
  assert.equal(harness.elements.copyDiagnosticsButton.dataset.copyState, "copying");
  assert.equal(harness.elements.copyDiagnosticsButton.attributes["aria-live"], "polite");
  assert.equal(harness.elements.copyDiagnosticsButton.attributes["aria-busy"], "true");
  assert.match(harness.elements.copyDiagnosticsButton.textContent, /コピー中/);

  copyResponse.resolve({ ok: true, text: "{\"diagnostics\":[]}" });
  await click;

  assert.equal(harness.runtimeMessages.at(-1).type, "copy_diagnostics");
  assert.equal(harness.clipboardText, "{\"diagnostics\":[]}");
  assert.equal(harness.elements.copyDiagnosticsButton.dataset.copyState, "copied");
  assert.equal(harness.elements.copyDiagnosticsButton.attributes["aria-live"], "polite");
  assert.equal(harness.elements.copyDiagnosticsButton.attributes["aria-busy"], "false");
  assert.equal(harness.elements.copyDiagnosticsButton.textContent, "コピーしました");
  assert.equal(harness.elements.reasonText.textContent, "診断ログをコピーしました。");
});

test("popup copy diagnostics failure visibly changes button state", async () => {
  const harness = loadJapanesePopupHarness({
    sendMessage: async (message) => {
      if (message.type === "get_status") return { ok: true, state: { status: "idle" } };
      if (message.type === "copy_diagnostics") return { ok: false, error: "copy_failed" };
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  await harness.elements.copyDiagnosticsButton.listeners.click();

  assert.equal(harness.elements.copyDiagnosticsButton.dataset.copyState, "failed");
  assert.equal(harness.elements.copyDiagnosticsButton.attributes["aria-live"], "polite");
  assert.equal(harness.elements.copyDiagnosticsButton.attributes["aria-busy"], "false");
  assert.equal(harness.elements.copyDiagnosticsButton.textContent, "コピー失敗");
  assert.equal(harness.elements.reasonText.textContent, "診断ログをコピーできませんでした。");
});

test("popup keeps key replacement discoverable when direct replacement needs setup guidance", async () => {
  const harness = loadJapanesePopupHarness({
    sendMessage: async (message) => {
      if (message.type === "get_status") {
        return { ok: true, state: { status: "idle", geminiApiKey: { configured: true, canReplace: false } } };
      }
      return { ok: true };
    },
  });
  await harness.dispatchDomReady();

  harness.context.setStatus({
    status: "idle",
    geminiApiKey: { configured: true, canReplace: false },
  });

  assert.equal(harness.elements.openKeySettingsButton.disabled, false);
  assert.equal(harness.elements.openKeySettingsButton.textContent, "APIキーを設定する");
  assert.match(harness.elements.reasonText.textContent, /Mimi Setup/);

  await harness.elements.openKeySettingsButton.listeners.click();
  assert.equal(harness.runtimeMessages.at(-1).type, "open_key_settings");
});

test("popup shows English as one en target without US/UK variants", async () => {
  const harness = loadPopupHarness({
    targetLanguages: [
      { code: "en", name: "English", flag: "🇺🇸" },
      { code: "ja", name: "Japanese", flag: "🇯🇵" },
    ],
  });
  await harness.dispatchDomReady();

  const englishOption = harness.elements.targetLanguage.children.find((option) => option.value === "en");

  assert.match(englishOption.textContent, /^🇺🇸\s/);
  assert.match(englishOption.textContent, /英語|English/);
  assert.equal(harness.elements.targetLanguage.children.filter((option) => /^en[-_]/i.test(option.value)).length, 0);
  assert.doesNotMatch(englishOption.textContent, /en-US|en-GB|United States|United Kingdom|UK|US English|British English/);
});

test("popup defaults to English UI and can switch to Japanese", async () => {
  const harness = loadPopupHarness();
  await harness.dispatchDomReady();

  assert.equal(harness.document.documentElement.lang, "en");
  assert.equal(harness.elements.uiLanguageJa.attributes["aria-pressed"], "false");
  assert.equal(harness.elements.uiLanguageEn.attributes["aria-pressed"], "true");
  assert.equal(harness.elements.targetLanguageLabel.textContent, "Listen in");
  assert.equal(harness.elements.startButton.textContent, "Start");
  assert.equal(harness.elements.usageText.textContent, "Monthly protection off");
  assert.match(harness.elements.targetLanguage.children[0].textContent, /Japanese/);

  await harness.elements.uiLanguageJa.listeners.click();

  assert.equal(harness.storageSet.mimiUiLanguageCode, "ja");
  assert.equal(harness.document.documentElement.lang, "ja");
  assert.equal(harness.elements.uiLanguageJa.attributes["aria-pressed"], "true");
  assert.equal(harness.elements.uiLanguageEn.attributes["aria-pressed"], "false");
  assert.equal(harness.elements.targetLanguageLabel.textContent, "何語で聞く？");
  assert.equal(harness.elements.startButton.textContent, "開始");
  assert.equal(harness.elements.usageText.textContent, "月間保護なし");
  assert.match(harness.elements.targetLanguage.children[0].textContent, /JP/);
});

function loadJapanesePopupHarness(options = {}) {
  return loadPopupHarness({
    ...options,
    storageGet: { ...options.storageGet, mimiUiLanguageCode: "ja" },
  });
}

function loadPopupHarness(options = {}) {
  const filePath = path.resolve(__dirname, "..", "src", "popup.js");
  const source = fs.readFileSync(filePath, "utf8");
  const elements = {};
  const documentListeners = {};
  const runtimeMessages = [];
  const ids = [
    "statusText",
    "usageText",
    "costText",
    "sourceText",
    "tokenText",
    "inputText",
    "outputText",
    "errorText",
    "reasonText",
    "extensionText",
    "transcriptText",
    "uiLanguageJa",
    "uiLanguageEn",
    "uiLanguageLabel",
    "targetLanguageLabel",
    "providerLabel",
    "providerOptions",
    "providerGeminiButton",
    "providerOpenAIButton",
    "providerGeminiName",
    "providerGeminiBadge",
    "providerGeminiDescription",
    "providerOpenAIName",
    "providerOpenAIBadge",
    "providerOpenAIDescription",
    "providerHint",
    "sourceLine",
    "sessionControls",
    "volumeControls",
    "originalVolumeLabel",
    "translatedVolumeLabel",
    "advancedSummary",
    "advancedContent",
    "settingsGrid",
    "monthlyLimitEnabledLabel",
    "limitMinutesLabel",
    "autoStopLabel",
    "sourceDetailLabel",
    "inputDetailLabel",
    "outputDetailLabel",
    "errorDetailLabel",
    "diagnosticDetailLabel",
    "extensionDetailLabel",
    "transcriptDetailLabel",
    "usageDetailLabel",
    "costDetailLabel",
    "tokenDetailLabel",
    "advancedNote",
    "targetLanguage",
    "diagnosticText",
    "startButton",
    "restartButton",
    "stopButton",
    "monthlyLimitEnabledInput",
    "limitMinutesInput",
    "saveLimitButton",
    "autoStopMinutesInput",
    "saveAutoStopButton",
    "resetUsageButton",
    "openKeySettingsButton",
    "downloadHelperLink",
    "copyDiagnosticsButton",
    "originalVolume",
    "translatedVolume",
    "originalVolumeValue",
    "translatedVolumeValue",
  ];
  for (const id of ids) elements[id] = makeElement(id);
  elements.uiLanguageJa.dataset.uiLanguage = "ja";
  elements.uiLanguageEn.dataset.uiLanguage = "en";
  elements.originalVolume.value = "35";
  elements.translatedVolume.value = "85";
  elements.providerGeminiButton.dataset.provider = "gemini";
  elements.providerOpenAIButton.dataset.provider = "openai";
  elements.providerGeminiButton.setAttribute("role", "radio");
  elements.providerOpenAIButton.setAttribute("role", "radio");
  elements.providerGeminiButton.setAttribute("aria-checked", "true");
  elements.providerGeminiButton.setAttribute("aria-pressed", "true");
  elements.providerOpenAIButton.setAttribute("aria-checked", "false");
  elements.providerOpenAIButton.setAttribute("aria-pressed", "false");
  const storageSet = {};
  const storageGet = options.storageGet || {};
  const documentStub = {
    activeElement: null,
    documentElement: {
      lang: "",
    },
    body: {
      dataset: {},
    },
    getElementById: (id) => elements[id],
    addEventListener: (name, listener) => {
      documentListeners[name] = listener;
    },
    createElement: () => makeElement("option"),
  };

  const context = {
    Date,
    Number,
    Math,
    Promise,
    clearInterval,
    setInterval: () => 1,
    document: documentStub,
    window: {
      MIMI_TARGET_LANGUAGES: options.targetLanguages || [{ code: "ja", name: "Japanese", flag: "JP" }],
      addEventListener: () => undefined,
    },
    navigator: {
      clipboard: {
        writeText: async (text) => {
          context.__clipboardText = text;
        },
      },
    },
    chrome: {
      runtime: {
        id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        sendMessage: async (message) => {
          runtimeMessages.push(message);
          if (options.sendMessage) return options.sendMessage(message);
          if (message.type === "get_status") return { ok: true, state: { status: "idle" } };
          return { ok: true };
        },
      },
      storage: {
        local: {
          get: async () => storageGet,
          set: async (value) => {
            Object.assign(storageSet, value);
          },
        },
      },
    },
  };
  vm.runInNewContext(source, context);
  return {
    context,
    document: documentStub,
    elements,
    runtimeMessages,
    storageSet,
    get clipboardText() {
      return context.__clipboardText;
    },
    dispatchDomReady: () => documentListeners.DOMContentLoaded(),
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((promiseResolve, promiseReject) => {
    resolve = promiseResolve;
    reject = promiseReject;
  });
  return { promise, resolve, reject };
}

function makeElement(id) {
  const element = {
    id,
    _textContent: "",
    value: "",
    disabled: false,
    attributes: {},
    dataset: {},
    style: {
      values: {},
      setProperty(name, value) {
        this.values[name] = value;
      },
    },
    listeners: {},
    append(child) {
      this.children = [...(this.children || []), child];
    },
    addEventListener(name, listener) {
      this.listeners[name] = listener;
    },
    setAttribute(name, value) {
      this.attributes[name] = value;
    },
    getAttribute(name) {
      return this.attributes[name];
    },
  };
  Object.defineProperty(element, "textContent", {
    get() {
      return this._textContent;
    },
    set(value) {
      this._textContent = value;
      if (value === "") this.children = [];
    },
  });
  return element;
}
