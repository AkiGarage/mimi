const OFFSCREEN_URL = "src/offscreen.html";
const SERVER_URL = "ws://127.0.0.1:8787/ws";
const SERVER_STATUS_URL = "http://127.0.0.1:8787/status";
const SERVER_EXTENSION_READY_URL = "http://127.0.0.1:8787/extension/ready";
const SERVER_SETTINGS_URL = "http://127.0.0.1:8787/settings";
const NATIVE_HOST_NAME = "com.akigarage.jp_dub";
const SERVER_READY_TIMEOUT_MS = 7000;
const SERVER_HEALTH_TIMEOUT_MS = 900;
const NATIVE_IDLE_EXIT_SECONDS = 600;
const START_WITH_DIAGNOSTICS = false;
const DIAGNOSTICS_STORAGE_KEY = "jpDubDiagnostics";
const LATEST_DIAGNOSTIC_STORAGE_KEY = "jpDubLatestDiagnostic";
const MAX_LOCAL_DIAGNOSTICS = 10;
const EXTENSION_ANNOUNCE_INTERVAL_MS = 2000;

let state = {
  status: "idle",
  mode: "real",
  error: "none",
  billing: null,
  inputBytes: 0,
  outputBytes: 0,
  targetLanguageCode: "ja",
  provider: "gemini",
  preferredProvider: "gemini",
  serverManagedByNative: false,
  lastStopReason: "",
  latestDiagnostic: null,
};
let startInFlight = null;
let lastExtensionAnnouncementAt = 0;

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.set({ jpDubInstalledAt: new Date().toISOString() });
  announceExtensionReady(true, "installed");
});

chrome.runtime.onStartup?.addListener(() => {
  announceExtensionReady(true, "startup");
});

chrome.action?.onUserSettingsChanged?.addListener(() => {
  announceExtensionReady(true, "toolbar_changed");
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.target && message.target !== "service-worker") return false;
  handleMessage(message, sender).then(sendResponse).catch((error) => {
    updateState({ status: "error", error: error.message });
    sendResponse({ ok: false, error: error.message });
  });
  return true;
});

async function handleMessage(message, sender) {
  if (message?.target === "service-worker") {
    handleOffscreenEvent(message);
    return { ok: true };
  }
  if (message?.type === "start") return startFromActiveTab(message);
  if (message?.type === "restart_start") return restartAndStartFromActiveTab(message);
  if (message?.type === "stop") return stopSession();
  if (message?.type === "set_volumes") return setVolumes(message);
  if (message?.type === "set_target_language") return setTargetLanguage(message);
  if (message?.type === "set_provider") return setProvider(message);
  if (message?.type === "reset_usage") return resetUsage();
  if (message?.type === "set_limit") return setLimit(message);
  if (message?.type === "open_key_settings") return openKeySettings();
  if (message?.type === "get_status") return getStatus();
  if (message?.type === "copy_diagnostics") return copyDiagnostics();
  return { ok: false, error: "unknown_message" };
}

async function startFromActiveTab(message) {
  if (startInFlight) return startInFlight;
  if (isStartAlreadyActive()) return { ok: true, state };
  return runStartOnce(() => startFromActiveTabInner(message));
}

async function restartAndStartFromActiveTab(message) {
  if (startInFlight) return startInFlight;
  return runStartOnce(() => restartAndStartFromActiveTabInner(message));
}

async function runStartOnce(startTask) {
  if (startInFlight) return startInFlight;
  startInFlight = (async () => {
    try {
      return await startTask();
    } catch (error) {
      const normalized = await recordStartupFailure(error);
      updateState({ status: "error", error: normalized.code, latestDiagnostic: normalized.diagnostic });
      throw new Error(normalized.code);
    } finally {
      startInFlight = null;
    }
  })();
  return startInFlight;
}

async function startFromActiveTabInner(message) {
  const provider = normalizeProvider(message.provider);
  if (!provider) throw new Error("unsupported_provider");
  updateState({
    status: "starting_server",
    error: "none",
    inputBytes: 0,
    outputBytes: 0,
    targetLanguageCode: normalizeTargetLanguageCode(message.targetLanguageCode),
    provider,
    lastStopReason: "",
    serverManagedByNative: false,
    latestDiagnostic: null,
  });
  const server = await ensureLocalServer({ diagnostics: START_WITH_DIAGNOSTICS });
  assertRealServerReady(server.status, state.provider);
  await startCapture(message, server);
  return { ok: true, state };
}

async function restartAndStartFromActiveTabInner(message) {
  const provider = normalizeProvider(message.provider);
  if (!provider) throw new Error("unsupported_provider");
  updateState({
    status: "restarting_server",
    error: "none",
    inputBytes: 0,
    outputBytes: 0,
    targetLanguageCode: normalizeTargetLanguageCode(message.targetLanguageCode),
    provider,
    lastStopReason: "",
    serverManagedByNative: false,
    latestDiagnostic: null,
  });
  await stopOffscreenSession("restart_server");
  const stopped = await sendNativeMessage({ type: "stop_server" }).catch((error) => {
    throw new Error(`native_host_unavailable:${error.message}`);
  });
  if (!stopped?.ok) throw new Error(stopped?.error || "native_stop_failed");
  const server = await ensureLocalServer({ diagnostics: START_WITH_DIAGNOSTICS, forceNative: true });
  assertRealServerReady(server.status, state.provider);
  await startCapture(message, server, { recoverExistingCapture: false });
  return { ok: true, state };
}

async function startCapture(message, server, options = {}) {
  updateState({ status: "connecting", mode: "real", serverManagedByNative: server.managedByNative });
  await prepareOffscreenForCapture(options);
  const tab = await getActiveTab();
  const streamId = await getStreamId(tab.id);
  await sendToOffscreen({
    target: "offscreen",
    type: "start",
    streamId,
    serverUrl: SERVER_URL,
    mode: "real",
    originalVolume: clampVolume(message.originalVolume, 0.35),
    translatedVolume: clampVolume(message.translatedVolume ?? message.japaneseVolume, 0.85),
    targetLanguageCode: state.targetLanguageCode,
    provider: state.provider,
    autoStopSeconds: normalizeAutoStopSeconds(message.autoStopMinutes),
  });
}

function assertRealServerReady(status, provider = "gemini") {
  if (status?.mode !== "real") {
    throw new Error("local_server_not_real_mode:restart the Mimi local server");
  }
  const providerStatus = status?.providers?.[provider];
  if (providerStatus && !providerStatus.configured) {
    throw new Error(`missing_${provider}_api_key:open Mimi API key settings`);
  }
  if (!providerStatus && provider === "gemini" && !status.realModeReady) {
    throw new Error("missing_gemini_api_key:run Mimi Setup or configure the local server developer fallback");
  }
  if (!providerStatus && provider !== "gemini") throw new Error("unsupported_provider");
  if (provider === "openai" && Number(status?.openaiBudget?.remainingSeconds || 0) <= 0) {
    throw new Error("openai_lifetime_budget_reached");
  }
  if (!status.allowedExtensionOriginConfigured) {
    throw new Error("missing_allowed_extension_origin:run native-host install with this extension origin");
  }
  assertExpectedExtensionIdentity(status);
}

async function stopSession() {
  await stopOffscreenSession("user_stopped");
  updateState({ status: "idle", serverManagedByNative: false });
  return { ok: true, state };
}

async function stopOffscreenSession(reason) {
  if (!(await chrome.offscreen.hasDocument())) return;
  await sendToOffscreen({ target: "offscreen", type: "stop", reason }).catch(() => null);
}

async function setVolumes(message) {
  const payload = {
    target: "offscreen",
    type: "set_volumes",
    originalVolume: clampVolume(message.originalVolume, 0.35),
    translatedVolume: clampVolume(message.translatedVolume ?? message.japaneseVolume, 0.85),
  };
  await sendToOffscreen(payload);
  return { ok: true, state };
}

async function setTargetLanguage(message) {
  updateState({ targetLanguageCode: normalizeTargetLanguageCode(message.targetLanguageCode) });
  return { ok: true, state };
}

async function setProvider(message) {
  if (isActiveStatus(state.status)) return { ok: false, error: "active_session_provider_locked", state };
  const provider = normalizeProvider(message.provider);
  if (!provider) throw new Error("unsupported_provider");
  const server = await ensureLocalServer({ diagnostics: START_WITH_DIAGNOSTICS });
  assertExpectedExtensionIdentity(server.status);
  const result = await postServerJson(`${SERVER_SETTINGS_URL}/provider`, { provider });
  if (!result.ok) throw new Error(result.error || "set_provider_failed");
  const preferredProvider = normalizeProvider(result.preferredProvider);
  updateState({ provider: preferredProvider, preferredProvider, error: "none", lastStopReason: "" });
  return { ok: true, preferredProvider, state };
}

async function resetUsage() {
  const server = await ensureLocalServer({ diagnostics: START_WITH_DIAGNOSTICS });
  assertExpectedExtensionIdentity(server.status);
  const result = await postServerJson(`${SERVER_SETTINGS_URL}/usage/reset`, {});
  if (!result.ok) throw new Error(result.error || "reset_usage_failed");
  updateState({ billing: result.billing, error: "none", lastStopReason: "" });
  return { ok: true, state };
}

async function setLimit(message) {
  const server = await ensureLocalServer({ diagnostics: START_WITH_DIAGNOSTICS });
  assertExpectedExtensionIdentity(server.status);
  const result = await postServerJson(`${SERVER_SETTINGS_URL}/limit`, {
    monthlyLimitEnabled: message.monthlyLimitEnabled === true,
    limitMinutes: message.limitMinutes,
  });
  if (!result.ok) throw new Error(result.error || "set_limit_failed");
  updateState({ billing: result.billing, error: "none", lastStopReason: "" });
  return { ok: true, state };
}

async function openKeySettings() {
  const server = await ensureLocalServer({ diagnostics: START_WITH_DIAGNOSTICS });
  assertExpectedExtensionIdentity(server.status);
  await chrome.tabs.create({ url: SERVER_SETTINGS_URL });
  return { ok: true, state };
}

async function getStatus() {
  await announceExtensionReady(true, "popup_opened");
  const latestDiagnostic = state.latestDiagnostic || await readLatestDiagnostic();
  const serverStatus = await fetchServerStatus().catch(() => null);
  if (isJpDubServer(serverStatus) && hasExpectedExtensionIdentity(serverStatus)) {
    updateState({
      billing: serverStatus.billing,
      openaiBudget: normalizeOpenAiBudget(serverStatus.openaiBudget),
      geminiApiKey: normalizeApiKeyStatus(serverStatus.geminiApiKey),
      openaiApiKey: normalizeApiKeyStatus(serverStatus.openaiApiKey),
      providers: normalizeProviderStatuses(serverStatus.providers),
      preferredProvider: normalizeProvider(serverStatus.preferredProvider),
      serverManagedByNative: Boolean(serverStatus.idleExitSeconds),
      latestDiagnostic,
    });
  } else if (latestDiagnostic) {
    updateState({ latestDiagnostic });
  }
  return { ok: true, state };
}

async function announceExtensionReady(force = false, event = "heartbeat") {
  if (!force && Date.now() - lastExtensionAnnouncementAt < EXTENSION_ANNOUNCE_INTERVAL_MS) return;
  const userSettings = await chrome.action?.getUserSettings?.().catch(() => null);
  const result = await postServerJson(SERVER_EXTENSION_READY_URL, {
    extensionId: expectedExtensionId(),
    isOnToolbar: userSettings?.isOnToolbar === true,
    event,
  }).catch(() => null);
  if (result?.ok) lastExtensionAnnouncementAt = Date.now();
}

async function copyDiagnostics() {
  return { ok: true, text: await buildDiagnosticsExport() };
}

function handleOffscreenEvent(message) {
  if (message.type === "status_event") updateState(message.patch || {});
}

async function ensureOffscreenDocument() {
  if (await chrome.offscreen.hasDocument()) return;
  await chrome.offscreen.createDocument({
    url: OFFSCREEN_URL,
    reasons: ["USER_MEDIA"],
    justification: "Capture the active tab audio and play translated audio.",
  });
}

async function prepareOffscreenForCapture(options = {}) {
  if (options.recoverExistingCapture !== false && await chrome.offscreen.hasDocument()) {
    await stopOffscreenSession("start_recovery");
  }
  await ensureOffscreenDocument();
}

async function getActiveTab() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tabs[0]?.id) throw new Error("active_tab_not_found");
  return tabs[0];
}

function getStreamId(targetTabId) {
  return new Promise((resolve, reject) => {
    chrome.tabCapture.getMediaStreamId({ targetTabId }, (streamId) => {
      const error = chrome.runtime.lastError;
      if (error) {
        const captureError = new Error(error.message);
        captureError.startupStage = "capture_stream";
        reject(captureError);
        return;
      }
      resolve(streamId);
    });
  });
}

function sendToOffscreen(message) {
  return chrome.runtime.sendMessage(message);
}

async function ensureLocalServer(options = {}) {
  const existing = await fetchServerStatus().catch(() => null);
  if (!options.forceNative && isJpDubServer(existing)) {
    if (!hasExpectedExtensionIdentity(existing)) {
      const stopped = await sendNativeMessage({ type: "stop_server" }).catch((error) => {
        throw new Error(`extension_origin_mismatch:restart Mimi Setup (${error.message})`);
      });
      if (!stopped?.ok) throw new Error(stopped?.error || "extension_origin_mismatch:restart Mimi Setup");
    } else if (!options.diagnostics || existing.diagnostics?.enabled || existing.mode !== "real") {
      return { managedByNative: Boolean(existing.idleExitSeconds), status: existing };
    } else {
      await sendNativeMessage({ type: "stop_server" }).catch(() => null);
    }
  }

  const response = await sendNativeMessage({
    type: "ensure_server",
    diagnostics: options.diagnostics === true,
    expectedExtensionId: expectedExtensionId(),
    idleExitSeconds: NATIVE_IDLE_EXIT_SECONDS,
    timeoutMs: SERVER_READY_TIMEOUT_MS,
  }).catch((error) => {
    throw new Error(`native_host_unavailable:${error.message}`);
  });
  if (!response?.ok) throw new Error(response?.error || "native_host_failed");

  const started = await waitForServerStatus(SERVER_READY_TIMEOUT_MS);
  return { managedByNative: true, status: started };
}

async function stopNativeManagedServer() {
  await sendNativeMessage({ type: "stop_server" }).catch(() => null);
}

async function waitForServerStatus(timeoutMs) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const status = await fetchServerStatus().catch(() => null);
    if (isJpDubServer(status)) return status;
    await delay(250);
  }
  throw new Error("local_server_start_timeout");
}

async function fetchServerStatus(timeoutMs = SERVER_HEALTH_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(SERVER_STATUS_URL, { cache: "no-store", signal: controller.signal });
    if (!response.ok) throw new Error(`status_http_${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

async function postServerJson(url, body, timeoutMs = SERVER_HEALTH_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method: "POST",
      cache: "no-store",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body || {}),
      signal: controller.signal,
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) return { ok: false, error: result.error || `http_${response.status}` };
    return result;
  } finally {
    clearTimeout(timer);
  }
}

function isJpDubServer(status) {
  return status?.ok === true && status.service === "jp-dub-local-server";
}

function assertExpectedExtensionIdentity(status) {
  const expectedId = expectedExtensionId();
  if (!expectedId) return;
  const actualId = String(status?.allowedExtensionId || "").trim();
  if (actualId !== expectedId) {
    throw new Error(`extension_origin_mismatch:local server allows ${actualId || "missing"} but this extension is ${expectedId}`);
  }
}

function hasExpectedExtensionIdentity(status) {
  try {
    assertExpectedExtensionIdentity(status);
    return true;
  } catch {
    return false;
  }
}

function expectedExtensionId() {
  return String(chrome.runtime.id || "").trim();
}

function sendNativeMessage(message) {
  return new Promise((resolve, reject) => {
    if (!chrome.runtime.sendNativeMessage) {
      reject(new Error("native_messaging_unavailable"));
      return;
    }
    chrome.runtime.sendNativeMessage(NATIVE_HOST_NAME, message, (response) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message));
        return;
      }
      resolve(response);
    });
  });
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isStartAlreadyActive() {
  return ["starting_server", "connecting", "capturing", "translating", "reconnecting"].includes(state.status);
}

async function recordStartupFailure(error) {
  const normalized = normalizeStartupError(error);
  await storeDiagnostic(normalized.diagnostic).catch(() => null);
  return normalized;
}

function normalizeStartupError(error) {
  const rawMessage = String(error?.message || error || "startup_failed");
  const stage = error?.startupStage || inferStartupStage(rawMessage);
  const code = isActiveStreamError(rawMessage) ? "capture_active_stream" : safeErrorCode(rawMessage);
  return {
    code,
    diagnostic: {
      timestamp: new Date().toISOString(),
      stage,
      code,
      detail: diagnosticDetail(code),
    },
  };
}

function inferStartupStage(message) {
  if (message.startsWith("native_host_unavailable") || message.startsWith("native_host_failed")) return "native_host";
  if (message.startsWith("local_server") || message.startsWith("missing_") || message.startsWith("extension_origin")) {
    return "local_server";
  }
  return "startup";
}

function isActiveStreamError(message) {
  return /can't capture a tab with an active stream/i.test(message);
}

function isProjectAccessDeniedDetail(value) {
  const text = String(value || "").toLowerCase();
  return text.includes("project has been denied access")
    || text.includes("permission_denied")
    || text.includes("access restricted")
    || /\b403\b/.test(text);
}

function safeErrorCode(message) {
  const code = String(message || "startup_failed").split(":")[0].trim();
  return /^[a-z0-9_]+$/.test(code) ? code : "startup_failed";
}

function normalizeDiagnosticCode(code, detail) {
  if (isProjectAccessDeniedDetail(detail)) return "gemini_project_access_denied";
  const safeCode = safeToken(code, "startup_failed");
  return safeCode === "network_error" && isProjectAccessDeniedDetail(detail)
    ? "gemini_project_access_denied"
    : safeCode;
}

function normalizeErrorCode(code, diagnostic) {
  const safeCode = safeToken(code, "none");
  if (safeCode === "gemini_project_access_denied") return "gemini_project_access_denied";
  if (safeCode === "network_error" && isProjectAccessDeniedDiagnostic(diagnostic)) {
    return "gemini_project_access_denied";
  }
  return safeCode;
}

function isProjectAccessDeniedDiagnostic(diagnostic) {
  return diagnostic?.code === "gemini_project_access_denied"
    || isProjectAccessDeniedDetail(diagnostic?.detail);
}

function diagnosticDetail(code) {
  if (code === "capture_active_stream") {
    return "Mimi/Chrome がこのタブの音声をすでに取得しています。Mimiを停止してもう一度開始してください。続く場合はタブを再読み込みし、それでも直らない場合はChromeを再起動してください。";
  }
  if (code === "gemini_project_access_denied") {
    return "Google/AI Studio が現在のGemini APIキーまたはプロジェクトを拒否しています。Gemini APIキーを入れ替えるか、AI Studio/Google Cloudのプロジェクト、請求、利用規約の表示を確認してください。プロジェクト自体が拒否されている場合はGoogleサポートに連絡してください。";
  }
  return "Mimiの開始に失敗しました。詳細設定の表示を確認し、必要ならMimi Setupまたはローカルヘルパーを確認してください。";
}

async function buildDiagnosticsExport() {
  const stored = await chrome.storage.local.get([
    DIAGNOSTICS_STORAGE_KEY,
    LATEST_DIAGNOSTIC_STORAGE_KEY,
    "jpDubState",
  ]).catch(() => ({}));
  const diagnostics = Array.isArray(stored?.[DIAGNOSTICS_STORAGE_KEY])
    ? stored[DIAGNOSTICS_STORAGE_KEY].map(sanitizeDiagnostic).filter(Boolean).slice(0, MAX_LOCAL_DIAGNOSTICS)
    : [];
  const latestDiagnostic = sanitizeDiagnostic(stored?.[LATEST_DIAGNOSTIC_STORAGE_KEY] || state.latestDiagnostic);
  const manifest = typeof chrome.runtime.getManifest === "function" ? chrome.runtime.getManifest() : {};
  return JSON.stringify({
    generatedAt: new Date().toISOString(),
    extension: {
      id: expectedExtensionId() || "unknown",
      name: sanitizeText(manifest.name || "Mimi"),
      version: sanitizeText(manifest.version || "unknown"),
    },
    state: sanitizeState(stored?.jpDubState || state),
    latestDiagnostic,
    diagnostics,
  }, null, 2);
}

function sanitizeState(value) {
  const source = value && typeof value === "object" ? value : {};
  const latestDiagnostic = sanitizeDiagnostic(source.latestDiagnostic);
  return {
    status: safeToken(source.status, "unknown"),
    mode: "real",
    error: normalizeErrorCode(source.error, latestDiagnostic),
    targetLanguageCode: normalizeTargetLanguageCode(source.targetLanguageCode),
    serverManagedByNative: Boolean(source.serverManagedByNative),
    lastStopReason: normalizeErrorCode(source.lastStopReason, latestDiagnostic),
    inputBytes: safeNonNegativeInteger(source.inputBytes),
    outputBytes: safeNonNegativeInteger(source.outputBytes),
    latestDiagnostic,
  };
}

function sanitizeDiagnostic(value) {
  if (!value || typeof value !== "object") return null;
  const code = normalizeDiagnosticCode(value.code, value.detail);
  return {
    timestamp: sanitizeTimestamp(value.timestamp),
    stage: safeToken(value.stage, "startup"),
    code,
    detail: code === "capture_active_stream" || code === "gemini_project_access_denied"
      ? diagnosticDetail(code)
      : sanitizeText(value.detail || diagnosticDetail(code), 500),
  };
}

function sanitizeTimestamp(value) {
  const text = String(value || "");
  return /^\d{4}-\d{2}-\d{2}T/.test(text) ? text.slice(0, 32) : new Date().toISOString();
}

function safeToken(value, fallback) {
  const text = String(value || fallback || "").trim();
  return /^[a-z0-9_:-]{0,80}$/i.test(text) ? text : fallback;
}

function safeNonNegativeInteger(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) return 0;
  return Math.min(999999999, Math.round(number));
}

function sanitizeText(value, maxLength = 120) {
  return redactSensitiveText(String(value || "")).slice(0, maxLength);
}

function redactSensitiveText(value) {
  return value
    .replace(/can't capture a tab with an active stream/gi, "[redacted_chrome_capture_error]")
    .replace(/https?:\/\/[^\s"')]+/gi, "[redacted_url]")
    .replace(/AIza[0-9A-Za-z_-]*/g, "[redacted_secret]")
    .replace(/gh[oprs]_[A-Za-z0-9_]+/g, "[redacted_secret]")
    .replace(/sk-[A-Za-z0-9_-]+/g, "[redacted_secret]")
    .replace(/-----BEGIN [^-]*PRIVATE KEY-----/gi, "[redacted_private_key]")
    .replace(/stream-[A-Za-z0-9_-]+/gi, "[redacted_stream]")
    .replace(/\b(password|credential|token|api[_ -]?key)\s*[:=]\s*[^\s,}]+/gi, "$1=[redacted_secret]")
    .replace(/\btranscript\s*[:=]\s*[^\n,}]+/gi, "transcript=[redacted_transcript]");
}

async function storeDiagnostic(diagnostic) {
  const stored = await chrome.storage.local.get(DIAGNOSTICS_STORAGE_KEY).catch(() => ({}));
  const previous = Array.isArray(stored?.[DIAGNOSTICS_STORAGE_KEY]) ? stored[DIAGNOSTICS_STORAGE_KEY] : [];
  const diagnostics = [diagnostic, ...previous].slice(0, MAX_LOCAL_DIAGNOSTICS);
  await chrome.storage.local.set({
    [DIAGNOSTICS_STORAGE_KEY]: diagnostics,
    [LATEST_DIAGNOSTIC_STORAGE_KEY]: diagnostic,
  });
}

async function readLatestDiagnostic() {
  const stored = await chrome.storage.local.get(LATEST_DIAGNOSTIC_STORAGE_KEY).catch(() => ({}));
  const diagnostic = stored?.[LATEST_DIAGNOSTIC_STORAGE_KEY];
  if (!isSafeDiagnostic(diagnostic)) return null;
  return diagnostic;
}

function isSafeDiagnostic(diagnostic) {
  return Boolean(
    diagnostic
    && typeof diagnostic.timestamp === "string"
    && typeof diagnostic.stage === "string"
    && typeof diagnostic.code === "string"
    && typeof diagnostic.detail === "string",
  );
}

function updateState(patch) {
  const nextPatch = {};
  for (const [key, value] of Object.entries(patch || {})) {
    if (value === undefined) continue;
    if (key === "latestDiagnostic") {
      nextPatch[key] = sanitizeDiagnostic(value);
    } else if (key === "geminiApiKey" || key === "openaiApiKey") {
      nextPatch[key] = normalizeApiKeyStatus(value);
    } else if (key === "openaiBudget") {
      nextPatch[key] = normalizeOpenAiBudget(value);
    } else if (key === "providers") {
      nextPatch[key] = normalizeProviderStatuses(value);
    } else if (key === "provider" || key === "preferredProvider") {
      const normalizedProvider = normalizeProvider(value);
      if (normalizedProvider) nextPatch[key] = normalizedProvider;
    } else {
      nextPatch[key] = value;
    }
  }
  if (nextPatch.latestDiagnostic) {
    const normalizedError = normalizeErrorCode(nextPatch.error ?? state.error, nextPatch.latestDiagnostic);
    const normalizedReason = normalizeErrorCode(nextPatch.lastStopReason ?? state.lastStopReason, nextPatch.latestDiagnostic);
    if (normalizedError === "gemini_project_access_denied") nextPatch.error = normalizedError;
    if (normalizedReason === "gemini_project_access_denied") nextPatch.lastStopReason = normalizedReason;
  }
  state = { ...state, ...nextPatch, mode: "real" };
  const storagePatch = { jpDubState: state };
  if (Object.prototype.hasOwnProperty.call(nextPatch, "latestDiagnostic")) {
    storagePatch[LATEST_DIAGNOSTIC_STORAGE_KEY] = state.latestDiagnostic;
  }
  chrome.storage.local.set(storagePatch);
}

function clampVolume(value, fallback) {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(1, Math.max(0, value));
}

function normalizeTargetLanguageCode(value) {
  const text = String(value || "ja").trim().toLowerCase();
  return /^[a-z]{2,3}$/.test(text) ? text : "ja";
}

function normalizeApiKeyStatus(value) {
  if (!value || typeof value !== "object") return null;
  const status = { configured: value.configured === true };
  if (typeof value.canReplace === "boolean") status.canReplace = value.canReplace;
  return status;
}

function normalizeProviderStatuses(value) {
  if (!value || typeof value !== "object") return null;
  const statuses = {};
  for (const provider of ["gemini", "openai"]) {
    const status = normalizeApiKeyStatus(value[provider]);
    if (status) statuses[provider] = status;
  }
  return statuses;
}

function normalizeOpenAiBudget(value) {
  if (!value || typeof value !== "object") return null;
  return {
    remainingSeconds: normalizeNonNegativeNumber(value.remainingSeconds),
    limitSeconds: normalizeNonNegativeNumber(value.limitSeconds),
    usedUsd: normalizeNonNegativeNumber(value.usedUsd),
  };
}

function normalizeNonNegativeNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}

function normalizeProvider(value) {
  if (value === undefined || value === null || String(value).trim() === "") return "gemini";
  const provider = String(value).trim().toLowerCase();
  if (provider === "xai" || provider === "grok") return "gemini";
  return provider === "gemini" || provider === "openai" ? provider : "";
}

function isActiveStatus(status) {
  return ["connecting", "capturing", "translating", "reconnecting", "starting_server", "restarting_server"].includes(status);
}

function normalizeAutoStopSeconds(minutes) {
  const value = Number(minutes);
  const normalized = Number.isFinite(value) && value > 0 ? value : 30;
  return Math.round(Math.min(120, Math.max(1, normalized)) * 60);
}
