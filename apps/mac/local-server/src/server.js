const http = require("http");
const { loadLocalEnv } = require("./localEnv");
const { BillingGuard } = require("./billingGuard");
const { GeminiLiveTranslateSession } = require("./geminiBridge");
const { OpenAIBudgetGuard } = require("./openaiBudgetGuard");
const { OpenAIRealtimeTranslateSession } = require("./openaiBridge");
const { ProviderPreferenceStore } = require("./providerPreference");
const { makeOriginPolicy } = require("./originPolicy");
const { attachWebSocketServer } = require("./websocket");
const { normalizeTargetLanguageCode } = require("./languages");
const { cumulativeUsageDelta, normalizeUsageMetadata } = require("./usageAccounting");
const { FirstOutputWavCapture } = require("./audioDebug");
const { DiagnosticsLog, analyzePcm16le, makeSessionId } = require("./diagnostics");
const {
  getGeminiApiKey,
  getOpenAIApiKey,
  makeGeminiApiKeyStatusCache,
  makeOpenAIApiKeyStatusCache,
  saveGeminiApiKey,
  saveOpenAIApiKey,
} = require("./secrets");
const { normalizeLimitMinutes, updateMonthlyLimitEnabled, updateMonthlyLimitMinutes } = require("./settings");
const { SetupProgressStore, markListeningStartedFromAudio } = require("./setupProgress");
const { settingsPageHtml } = require("./settingsPage");
const { resolveExtensionOriginDetails } = require("../../shared/extensionOrigin.cjs");

loadLocalEnv();

const PORT = Number(process.env.JP_DUB_PORT || 8787);
const MODE = "real";
const TARGET_LANGUAGE = normalizeTargetLanguageCode(process.env.JP_DUB_TARGET_LANGUAGE, "ja") || "ja";
const MODEL = process.env.JP_DUB_MODEL || "gemini-3.5-live-translate-preview";
const OPENAI_MODEL = "gpt-realtime-translate";
const RECONNECT_SECONDS = Number(process.env.JP_DUB_RECONNECT_SECONDS || 540);
const BILLING_UPDATE_INTERVAL_MS = 1000;
const IDLE_EXIT_SECONDS = Number(process.env.JP_DUB_IDLE_EXIT_SECONDS || 0);
const DIAGNOSTICS_ENABLED = readBooleanEnv("JP_DUB_DIAGNOSTICS", false);
const CAPTURE_FIRST_OUTPUT_WAV = readBooleanEnv("JP_DUB_CAPTURE_FIRST_OUTPUT_WAV", DIAGNOSTICS_ENABLED);
const CAPTURE_FIRST_INPUT_WAV = readBooleanEnv("JP_DUB_CAPTURE_FIRST_INPUT_WAV", DIAGNOSTICS_ENABLED);
const CAPTURE_FIRST_OUTPUT_SECONDS = Number(process.env.JP_DUB_CAPTURE_FIRST_OUTPUT_SECONDS || 4);
const CAPTURE_FIRST_INPUT_SECONDS = Number(process.env.JP_DUB_CAPTURE_FIRST_INPUT_SECONDS || CAPTURE_FIRST_OUTPUT_SECONDS);
const DIAGNOSTIC_AUDIO_CHUNK_LIMIT = 12;
const ALLOWED_EXTENSION_ORIGIN_DETAILS = resolveExtensionOriginDetails();
const ALLOWED_EXTENSION_ORIGIN = ALLOWED_EXTENSION_ORIGIN_DETAILS.origin;
const isAllowedOrigin = makeOriginPolicy({
  mode: MODE,
  allowedExtensionOrigin: ALLOWED_EXTENSION_ORIGIN,
});
const guard = new BillingGuard();
const openaiGuard = new OpenAIBudgetGuard();
const providerPreference = new ProviderPreferenceStore({
  filePath: process.env.JP_DUB_PROVIDER_PREFERENCE_FILE || undefined,
});
const diagnostics = new DiagnosticsLog({ enabled: DIAGNOSTICS_ENABLED });
const setupProgress = new SetupProgressStore();
const sessions = new Set();
const geminiStatusCache = makeGeminiApiKeyStatusCache();
const openaiStatusCache = makeOpenAIApiKeyStatusCache();
let lastSessionSnapshot = null;
let idleExitTimer = null;
let extensionLastSeenAt = null;
let extensionIsOnToolbar = false;
let extensionInstalledAt = null;
let extensionToolbarChangedAt = null;
let extensionPopupOpenedAt = null;

function jsonResponse(response, statusCode, value) {
  const body = JSON.stringify(value, null, 2);
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  response.end(body);
}

function htmlResponse(response, statusCode, body) {
  response.writeHead(statusCode, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "content-security-policy": "frame-ancestors 'none'",
    "x-frame-options": "DENY",
  });
  response.end(body);
}

function serverStatus() {
  const geminiStatus = geminiStatusCache.get();
  const openaiStatus = openaiStatusCache.get();
  const openaiBudget = openaiGuard.snapshot();
  return {
    ok: true,
    service: "jp-dub-local-server",
    mode: MODE,
    targetLanguage: TARGET_LANGUAGE,
    model: MODEL,
    activeSessions: sessions.size,
    sessions: Array.from(sessions).map((session) => sessionStatsSnapshot(session)),
    lastSession: lastSessionSnapshot,
    billing: guard.snapshot(),
    openaiBudget,
    geminiApiKey: geminiStatus,
    openaiApiKey: openaiStatus,
    preferredProvider: providerPreference.get(),
    providers: {
      gemini: { configured: geminiStatus.configured, model: MODEL, paid: false },
      openai: { configured: openaiStatus.configured, model: OPENAI_MODEL, paid: true, budget: openaiBudget },
    },
    realModeReady: geminiStatus.configured,
    allowedExtensionOriginConfigured: Boolean(ALLOWED_EXTENSION_ORIGIN),
    allowedExtensionOrigin: ALLOWED_EXTENSION_ORIGIN,
    allowedExtensionId: ALLOWED_EXTENSION_ORIGIN_DETAILS.extensionId || "",
    allowedExtensionOriginSource: ALLOWED_EXTENSION_ORIGIN_DETAILS.source || "missing",
    setupProgress: setupProgress.snapshot(),
    extensionConnection: {
      verified: Boolean(extensionLastSeenAt),
      lastSeenAt: extensionLastSeenAt,
      isOnToolbar: extensionIsOnToolbar,
      installedAt: extensionInstalledAt,
      toolbarChangedAt: extensionToolbarChangedAt,
      popupOpenedAt: extensionPopupOpenedAt,
    },
    idleExitSeconds: IDLE_EXIT_SECONDS,
    diagnostics: {
      ...diagnostics.snapshot(),
      captureFirstInputWav: CAPTURE_FIRST_INPUT_WAV,
      captureFirstOutputWav: CAPTURE_FIRST_OUTPUT_WAV,
      captureFirstInputSeconds: CAPTURE_FIRST_INPUT_SECONDS,
      captureFirstOutputSeconds: CAPTURE_FIRST_OUTPUT_SECONDS,
    },
  };
}

const server = http.createServer((request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    recordExtensionConnection(request);
    jsonResponse(response, 200, serverStatus());
    return;
  }
  if (request.method === "GET" && request.url === "/status") {
    recordExtensionConnection(request);
    jsonResponse(response, 200, serverStatus());
    return;
  }
  if (request.method === "POST" && request.url === "/extension/ready") {
    handleExtensionReady(request, response);
    return;
  }
  if (request.method === "GET" && request.url === "/settings") {
    htmlResponse(response, 200, settingsPageHtml(serverStatus()));
    return;
  }
  if (request.method === "POST" && request.url === "/settings/usage/reset") {
    handleControlRequest(request, response, () => {
      const backupPath = guard.resetUsage();
      return { ok: true, billing: guard.snapshot(), reset: { backupCreated: Boolean(backupPath) } };
    });
    return;
  }
  if (request.method === "POST" && request.url === "/settings/limit") {
    handleControlRequest(request, response, (body) => {
      if (body.monthlyLimitEnabled === false) {
        updateMonthlyLimitEnabled(false);
        guard.disableMonthlyLimit();
        return { ok: true, billing: guard.snapshot() };
      }
      const limitMinutes = updateMonthlyLimitMinutes(body.limitMinutes);
      guard.setLimitSeconds(normalizeLimitMinutes(limitMinutes) * 60);
      return { ok: true, billing: guard.snapshot() };
    });
    return;
  }
  if (request.method === "POST" && request.url === "/settings/provider") {
    handleControlRequest(request, response, (body) => {
      if (Array.from(sessions).some((session) => session.started)) {
        throw new Error("active_session_provider_locked");
      }
      return {
        ok: true,
        preferredProvider: providerPreference.set(body.provider),
      };
    });
    return;
  }
  if (request.method === "POST" && request.url === "/settings/api-key") {
    handleControlRequest(request, response, (body) => {
      const requestedProvider = body.provider || "gemini";
      const provider = normalizeProvider(requestedProvider);
      if (!provider) throw new Error("unsupported_provider");
      if (provider === "openai") {
        const status = saveOpenAIApiKey(body.apiKey);
        openaiStatusCache.set(status);
        return { ok: true, provider, openaiApiKey: status };
      }
      const status = saveGeminiApiKey(body.apiKey);
      geminiStatusCache.set(status);
      return { ok: true, provider: "gemini", geminiApiKey: status };
    });
    return;
  }
  jsonResponse(response, 404, { ok: false, error: "not_found" });
});

function recordExtensionConnection(request) {
  const origin = request.headers.origin || "";
  if (origin && isAllowedOrigin(origin)) {
    extensionLastSeenAt = new Date().toISOString();
  }
}

function handleExtensionReady(request, response) {
  const origin = request.headers.origin || "";
  if (!isAllowedOrigin(origin)) {
    jsonResponse(response, 403, { ok: false, error: "origin_not_allowed" });
    return;
  }
  readJsonBody(request)
    .then((body) => {
      const extensionId = String(body?.extensionId || "").trim();
      if (!extensionId || extensionId !== ALLOWED_EXTENSION_ORIGIN_DETAILS.extensionId) {
        jsonResponse(response, 403, { ok: false, error: "extension_id_not_allowed" });
        return;
      }
      extensionLastSeenAt = new Date().toISOString();
      extensionIsOnToolbar = body?.isOnToolbar === true;
      if (body?.event === "installed") extensionInstalledAt = extensionLastSeenAt;
      if (body?.event === "toolbar_changed") extensionToolbarChangedAt = extensionLastSeenAt;
      if (body?.event === "popup_opened") {
        extensionPopupOpenedAt = extensionLastSeenAt;
        extensionInstalledAt ||= extensionLastSeenAt;
        if (extensionIsOnToolbar) extensionToolbarChangedAt ||= extensionLastSeenAt;
      }
      jsonResponse(response, 200, { ok: true, extensionConnection: serverStatus().extensionConnection });
    })
    .catch((error) => {
      jsonResponse(response, 400, { ok: false, error: error.message || "invalid_json" });
    });
}

function handleControlRequest(request, response, handler) {
  if (!isAllowedControlOrigin(request)) {
    jsonResponse(response, 403, { ok: false, error: "origin_not_allowed" });
    return;
  }
  readJsonBody(request)
    .then((body) => {
      try {
        jsonResponse(response, 200, handler(body || {}));
      } catch (error) {
        jsonResponse(response, 400, { ok: false, error: error.message || "settings_failed" });
      }
    })
    .catch((error) => {
      jsonResponse(response, 400, { ok: false, error: error.message || "invalid_json" });
    });
}

function isAllowedControlOrigin(request) {
  const origin = request.headers.origin || "";
  if (!origin) return true;
  if (origin === `http://127.0.0.1:${PORT}` || origin === `http://localhost:${PORT}`) return true;
  return isAllowedOrigin(origin);
}

function readJsonBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > 64 * 1024) {
        reject(new Error("body_too_large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8").trim();
      if (!text) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new Error("invalid_json"));
      }
    });
    request.on("error", reject);
  });
}

attachWebSocketServer(server, {
  path: "/ws",
  isAllowedOrigin,
  onConnection: (peer, request) => handleConnection(peer, request),
});

function handleConnection(peer, request) {
  cancelIdleExit();
  const session = createClientSession(peer);
  sessions.add(session);
  diagnostics.record("client_connected", {
    sessionId: session.id,
    origin: request?.headers?.origin || "",
    activeSessions: sessions.size,
  });
  peer.sendText({ type: "status", status: "connected", mode: "real", billing: guard.snapshot() });
  peer.onMessage((frame) => handleFrame(session, frame));
  peer.onClose(() => closeClientSession(session, "client_closed"));
}

function createClientSession(peer) {
  const id = makeSessionId();
  const session = {
    id,
    peer,
    mode: MODE,
    provider: "gemini",
    translation: null,
    reconnectTimer: null,
    lastBillingSentAt: 0,
    started: false,
    successfulListeningRecorded: false,
    startedAtMs: Date.now(),
    inputDiagnosticChunks: 0,
    outputDiagnosticChunks: 0,
    stats: {
      sessionId: id,
      connectedAt: new Date().toISOString(),
      status: "connected",
      inputBytes: 0,
      outputBytes: 0,
      capturedInputBytes: 0,
      inputTranscript: "",
      outputTranscript: "",
      usage: { inputTokens: 0, outputTokens: 0, totalTokens: 0, unknownTokens: 0 },
      lastErrorCode: "",
      lastError: "",
      lastReason: "",
      diagnosticsLog: diagnostics.snapshot().logPath,
      firstInputWav: "",
      firstOutputWav: "",
    },
    targetLanguageCode: TARGET_LANGUAGE,
    lastUsageMetadata: null,
    captureRun: 0,
    inputCapture: makeInputCapture(id, 0),
    outputCapture: makeOutputCapture(id, 0),
  };
  return session;
}

function handleFrame(session, frame) {
  if (frame.opcode === 0x2) {
    handleAudioInput(session, frame.payload);
    return;
  }
  if (frame.opcode !== 0x1) return;
  const message = parseMessage(frame.payload);
  if (!message) {
    session.peer.sendText({ type: "error", error: "invalid_json" });
    return;
  }
  if (message.type === "start") {
    startSession(session, resolveMode(message.mode), message.targetLanguageCode, message.provider);
  }
  if (message.type === "stop") stopSession(session, message.reason || "user_stopped");
  if (message.type === "audio_stream_end") handleAudioStreamEnd(session);
}

function parseMessage(payload) {
  try {
    return JSON.parse(payload.toString("utf8"));
  } catch {
    return null;
  }
}

function resolveMode(requestedMode) {
  if (!requestedMode || requestedMode === "real") return "real";
  return "invalid_mode";
}

function normalizeProvider(value) {
  if (value === undefined) return "gemini";
  const provider = String(value).trim().toLowerCase();
  return provider === "gemini" || provider === "openai" ? provider : "";
}

function startSession(session, mode, requestedTargetLanguageCode, requestedProvider) {
  stopSession(session, "restart");
  const targetLanguageCode = normalizeTargetLanguageCode(requestedTargetLanguageCode, TARGET_LANGUAGE);
  const provider = requestedProvider === undefined
    ? providerPreference.get()
    : normalizeProvider(requestedProvider);
  diagnostics.record("session_start_requested", {
    sessionId: session.id,
    mode,
    provider: provider || requestedProvider || "",
    targetLanguageCode: targetLanguageCode || requestedTargetLanguageCode || "",
  });
  if (!targetLanguageCode) {
    session.peer.sendText({ type: "error", error: "unsupported_target_language", billing: guard.snapshot() });
    return;
  }
  if (mode !== "real") {
    session.peer.sendText({ type: "error", error: mode, billing: guard.snapshot() });
    return;
  }
  if (!provider) {
    session.peer.sendText({ type: "error", error: "unsupported_provider", billing: guard.snapshot() });
    return;
  }
  session.mode = mode;
  session.provider = provider;
  session.targetLanguageCode = targetLanguageCode;
  session.started = true;
  session.lastBillingSentAt = 0;
  resetStartupDiagnostics(session);
  session.peer.sendText({ type: "audio_format", sampleRate: 24000, channels: 1, encoding: "pcm_s16le" });
  startRealSession(session);
}

function startRealSession(session) {
  const apiKey = getProviderApiKey(session.provider);
  if (!apiKey) {
    session.started = false;
    diagnostics.record("session_start_blocked", {
      sessionId: session.id,
      provider: session.provider,
      reason: "missing_api_key",
    });
    session.peer.sendText({
      type: "error",
      error: `missing_${session.provider}_api_key`,
      provider: session.provider,
      targetLanguageCode: session.targetLanguageCode,
      billing: guard.snapshot(),
      openaiBudget: openaiGuard.snapshot(),
    });
    return;
  }
  if (session.provider === "openai" && !openaiGuard.canUse(0.001)) {
    session.started = false;
    session.peer.sendText({
      type: "error",
      error: "openai_lifetime_budget_reached",
      provider: session.provider,
      openaiBudget: openaiGuard.snapshot(),
    });
    return;
  }
  session.lastUsageMetadata = null;
  updateSessionStats(session, { status: "connecting", lastReason: "" });
  diagnostics.record(`${session.provider}_connecting`, {
    sessionId: session.id,
    targetLanguageCode: session.targetLanguageCode,
    model: session.provider === "openai" ? OPENAI_MODEL : MODEL,
    echoTargetLanguage: process.env.JP_DUB_ALLOW_TARGET_LANGUAGE_ECHO === "true",
  });
  session.peer.sendText({
    type: "status",
    status: "connecting",
    mode: "real",
    provider: session.provider,
    targetLanguageCode: session.targetLanguageCode,
    billing: guard.snapshot(),
    openaiBudget: openaiGuard.snapshot(),
  });
  session.translation = makeTranslationSession(session, apiKey);
  try {
    session.translation.start();
  } catch (error) {
    handleProviderError(session, error.message || `${session.provider}_start_failed`, "");
    return;
  }
  session.reconnectTimer = setTimeout(() => reconnectRealSession(session), RECONNECT_SECONDS * 1000);
}

function getProviderApiKey(provider) {
  if (provider === "openai") return getOpenAIApiKey();
  return getGeminiApiKey();
}

function makeTranslationSession(session, apiKey) {
  if (session.provider === "openai") return makeOpenAISession(session, apiKey);
  return makeGeminiSession(session, apiKey);
}

function makeGeminiSession(session, apiKey) {
  return new GeminiLiveTranslateSession({
    apiKey,
    model: MODEL,
    endpoint: process.env.JP_DUB_GEMINI_ENDPOINT,
    targetLanguageCode: session.targetLanguageCode,
    echoTargetLanguage: process.env.JP_DUB_ALLOW_TARGET_LANGUAGE_ECHO === "true",
    callbacks: {
      onStatus: (status) => {
        updateSessionStats(session, { status });
        diagnostics.record("gemini_status", { sessionId: session.id, status });
        session.peer.sendText({
          type: "status",
          status,
          mode: "real",
          provider: session.provider,
          targetLanguageCode: session.targetLanguageCode,
          billing: guard.snapshot(),
        });
      },
      onAudio: (audio) => {
        markListeningStartedFromAudio(session, audio, setupProgress, (error) => {
          diagnostics.record("setup_progress_write_failed", {
            sessionId: session.id,
            errorCode: error?.code || "write_failed",
          });
        });
        guard.recordOutput(audio.length / (24000 * 2));
        const firstOutputWav = session.outputCapture.addAudio(audio);
        maybeRecordAudioDiagnostic(session, "output", audio, 24000);
        updateSessionStats(session, {
          outputBytes: session.stats.outputBytes + audio.length,
          ...(firstOutputWav ? { firstOutputWav } : {}),
        });
        if (firstOutputWav) {
          diagnostics.record("first_output_wav_saved", { sessionId: session.id, filePath: firstOutputWav });
        }
        session.peer.sendBinary(audio);
        sendBillingUpdate(session);
      },
      shouldSendAudio: (audio) => canRecordBillableAudio(session, audio.length),
      onInputAudioSent: (byteLength) => recordBillableInputAudio(session, byteLength),
      onUsage: (usage) => handleUsageMetadata(session, usage),
      onTranscript: (value) => {
        const key = value.kind === "input" ? "inputTranscript" : "outputTranscript";
        updateSessionStats(session, { [key]: value.text });
        session.peer.sendText({ type: "transcript", ...value });
      },
      onError: (error, detail) => handleProviderError(session, error, detail),
    },
  });
}

function makeOpenAISession(session, apiKey) {
  return new OpenAIRealtimeTranslateSession({
    apiKey,
    model: OPENAI_MODEL,
    targetLanguageCode: session.targetLanguageCode,
    callbacks: {
      onStatus: (status) => {
        updateSessionStats(session, { status });
        diagnostics.record("openai_status", { sessionId: session.id, status });
        session.peer.sendText({
          type: "status",
          status,
          mode: "real",
          provider: session.provider,
          targetLanguageCode: session.targetLanguageCode,
          billing: guard.snapshot(),
          openaiBudget: openaiGuard.snapshot(),
        });
      },
      onAudio: (audio) => {
        markListeningStartedFromAudio(session, audio, setupProgress, () => {});
        const firstOutputWav = session.outputCapture.addAudio(audio);
        maybeRecordAudioDiagnostic(session, "output", audio, 24000);
        updateSessionStats(session, {
          outputBytes: session.stats.outputBytes + audio.length,
          ...(firstOutputWav ? { firstOutputWav } : {}),
        });
        session.peer.sendBinary(audio);
        sendBillingUpdate(session);
      },
      shouldSendAudio: (audio) => reserveProviderAudio(session, audio.length),
      onInputAudioSent: (byteLength) => recordProviderInputAudio(session, byteLength),
      onTranscript: (value) => {
        updateSessionStats(session, { outputTranscript: value.text });
        session.peer.sendText({ type: "transcript", ...value });
      },
      onError: (error, detail) => handleProviderError(session, error, detail),
    },
  });
}

function handleAudioInput(session, buffer) {
  if (!session.started) return;
  const firstInputWav = session.inputCapture.addAudio(buffer);
  maybeRecordAudioDiagnostic(session, "input", buffer, 16000);
  updateSessionStats(session, {
    capturedInputBytes: session.stats.capturedInputBytes + buffer.length,
    ...(firstInputWav ? { firstInputWav } : {}),
  });
  if (firstInputWav) {
    diagnostics.record("first_input_wav_saved", { sessionId: session.id, filePath: firstInputWav });
  }
  if (session.mode !== "real" || !session.translation) return;
  const sent = session.translation.sendAudio(buffer);
  if (!sent && session.started) {
    session.peer.sendText({
      type: "status",
      status: "connecting",
      mode: "real",
      provider: session.provider,
      targetLanguageCode: session.targetLanguageCode,
      billing: guard.snapshot(),
      ...(session.provider === "openai" ? { openaiBudget: openaiGuard.snapshot() } : {}),
    });
  }
}

function handleAudioStreamEnd(session) {
  diagnostics.record("audio_stream_end", { sessionId: session.id });
  if (session.mode === "real" && session.translation) session.translation.sendAudioStreamEnd();
}

function reserveProviderAudio(session, byteLength) {
  if (session.provider !== "openai") return canRecordBillableAudio(session, byteLength);
  const seconds = byteLength / (16000 * 2);
  if (openaiGuard.reserve(seconds)) return true;
  stopSession(session, "openai_lifetime_budget_reached");
  session.peer.sendText({
    type: "error",
    error: "openai_lifetime_budget_reached",
    provider: session.provider,
    openaiBudget: openaiGuard.snapshot(),
  });
  return false;
}

function recordProviderInputAudio(session, byteLength) {
  if (session.provider !== "openai") {
    recordBillableInputAudio(session, byteLength);
    return;
  }
  updateSessionStats(session, { inputBytes: session.stats.inputBytes + byteLength });
  sendBillingUpdate(session);
}

function canRecordBillableAudio(session, byteLength) {
  const seconds = byteLength / (16000 * 2);
  if (!guard.canUse(seconds)) {
    stopSession(session, "monthly_limit_reached");
    session.peer.sendText({ type: "error", error: "monthly_limit_reached", billing: guard.snapshot() });
    return false;
  }
  return true;
}

function recordBillableInputAudio(session, byteLength) {
  const seconds = byteLength / (16000 * 2);
  guard.record(seconds);
  updateSessionStats(session, { inputBytes: session.stats.inputBytes + byteLength });
  sendBillingUpdate(session);
}

function handleUsageMetadata(session, usageMetadata) {
  const current = normalizeUsageMetadata(usageMetadata);
  const delta = cumulativeUsageDelta(session.lastUsageMetadata, current);
  session.lastUsageMetadata = current;
  guard.recordTokens(delta);
  updateSessionStats(session, { usage: addTokenUsage(session.stats.usage, delta) });
  session.peer.sendText({ type: "billing", billing: guard.snapshot() });
}

function addTokenUsage(current, delta) {
  return {
    inputTokens: current.inputTokens + delta.inputTokens,
    outputTokens: current.outputTokens + delta.outputTokens,
    totalTokens: current.totalTokens + delta.totalTokens,
    unknownTokens: current.unknownTokens + delta.unknownTokens,
  };
}

function reconnectRealSession(session) {
  if (!session.started || session.mode !== "real") return;
  const apiKey = getProviderApiKey(session.provider);
  if (!apiKey) {
    handleProviderError(session, `missing_${session.provider}_api_key`, "");
    return;
  }
  diagnostics.record(`${session.provider}_reconnecting`, { sessionId: session.id });
  session.peer.sendText({
    type: "status",
    status: "reconnecting",
    mode: "real",
    provider: session.provider,
    targetLanguageCode: session.targetLanguageCode,
    billing: guard.snapshot(),
    openaiBudget: openaiGuard.snapshot(),
  });
  if (session.translation) session.translation.stop();
  session.lastUsageMetadata = null;
  session.translation = makeTranslationSession(session, apiKey);
  try {
    session.translation.start();
  } catch (error) {
    handleProviderError(session, error.message || `${session.provider}_start_failed`, "");
    return;
  }
  session.reconnectTimer = setTimeout(() => reconnectRealSession(session), RECONNECT_SECONDS * 1000);
}

function handleProviderError(session, error, detail) {
  updateSessionStats(session, { status: "error", lastErrorCode: error, lastError: detail || error });
  diagnostics.record(`${session.provider}_error`, { sessionId: session.id, error, detail });
  stopSession(session, error);
  lastSessionSnapshot = sessionStatsSnapshot(session);
  session.peer.sendText({
    type: "error",
    error,
    detail,
    provider: session.provider,
    targetLanguageCode: session.targetLanguageCode,
    billing: guard.snapshot(),
    openaiBudget: openaiGuard.snapshot(),
  });
}

function stopSession(session, reason) {
  flushAudioCaptures(session, reason);
  if (session.reconnectTimer) clearTimeout(session.reconnectTimer);
  if (session.translation) session.translation.stop();
  session.reconnectTimer = null;
  session.translation = null;
  session.started = false;
  updateSessionStats(session, { status: "idle", lastReason: reason });
  diagnostics.record("session_stopped", {
    sessionId: session.id,
    reason,
    inputBytes: session.stats.inputBytes,
    capturedInputBytes: session.stats.capturedInputBytes,
    outputBytes: session.stats.outputBytes,
    firstInputWav: session.stats.firstInputWav,
    firstOutputWav: session.stats.firstOutputWav,
  });
  session.peer.sendText({
    type: "status",
    status: "idle",
    mode: session.mode,
    provider: session.provider,
    targetLanguageCode: session.targetLanguageCode,
    reason,
    billing: guard.snapshot(),
    openaiBudget: openaiGuard.snapshot(),
  });
}

function closeClientSession(session, reason) {
  stopSession(session, reason);
  lastSessionSnapshot = sessionStatsSnapshot(session);
  sessions.delete(session);
  diagnostics.record("client_closed", { sessionId: session.id, reason, activeSessions: sessions.size });
  scheduleIdleExit("client_closed");
}

function updateSessionStats(session, patch) {
  Object.assign(session.stats, patch, { updatedAt: new Date().toISOString() });
}

function sendBillingUpdate(session) {
  const now = Date.now();
  if (now - session.lastBillingSentAt < BILLING_UPDATE_INTERVAL_MS) return;
  session.lastBillingSentAt = now;
  session.peer.sendText({
    type: "billing",
    billing: guard.snapshot(),
    openaiBudget: openaiGuard.snapshot(),
  });
}

function sessionStatsSnapshot(session) {
  return {
    id: session.id,
    mode: session.mode,
    provider: session.provider,
    targetLanguageCode: session.targetLanguageCode,
    started: session.started,
    ...session.stats,
  };
}

function scheduleIdleExit(reason) {
  if (!IDLE_EXIT_SECONDS || sessions.size > 0 || idleExitTimer) return;
  diagnostics.record("idle_exit_scheduled", { reason, idleExitSeconds: IDLE_EXIT_SECONDS });
  idleExitTimer = setTimeout(() => {
    console.log(`JP Dub local server idle exit after ${IDLE_EXIT_SECONDS}s (${reason}).`);
    shutdown("idle_exit");
  }, IDLE_EXIT_SECONDS * 1000);
  idleExitTimer.unref();
}

function cancelIdleExit() {
  if (!idleExitTimer) return;
  clearTimeout(idleExitTimer);
  idleExitTimer = null;
}

function shutdown(reason) {
  cancelIdleExit();
  for (const session of sessions) flushAudioCaptures(session, reason);
  diagnostics.record("server_shutdown", { reason });
  guard.flush();
  openaiGuard.flush();
  console.log(`JP Dub local server shutting down: ${reason}`);
  cleanupPidFile();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000).unref();
}

function cleanupPidFile() {
  const fs = require("fs");
  const path = require("path");
  const pidFile = path.resolve(__dirname, "..", "..", "..", "..", "tmp", "jp-dub-local-server.pid");
  try {
    const pid = Number(fs.readFileSync(pidFile, "utf8").trim());
    if (pid === process.pid) fs.unlinkSync(pidFile);
  } catch {
    // Ignore missing or stale pid files.
  }
}

server.on("error", (error) => {
  if (error.code === "EADDRINUSE") {
    diagnostics.record("server_start_failed", { error: "EADDRINUSE", port: PORT });
    console.error(`JP Dub local server cannot start: 127.0.0.1:${PORT} is already in use.`);
    console.error(`Run: lsof -nP -iTCP:${PORT} -sTCP:LISTEN`);
    console.error("If the process is not JP Dub, stop it and run npm start again.");
    process.exit(1);
  }
  throw error;
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`JP Dub local server listening on http://127.0.0.1:${PORT}`);
  diagnostics.record("server_started", {
    port: PORT,
    mode: MODE,
    diagnosticsEnabled: DIAGNOSTICS_ENABLED,
    captureFirstInputWav: CAPTURE_FIRST_INPUT_WAV,
    captureFirstOutputWav: CAPTURE_FIRST_OUTPUT_WAV,
    idleExitSeconds: IDLE_EXIT_SECONDS,
  });
  scheduleIdleExit("startup");
});

process.once("SIGTERM", () => shutdown("sigterm"));
process.once("SIGINT", () => shutdown("sigint"));

function maybeRecordAudioDiagnostic(session, kind, audio, sampleRate) {
  const key = kind === "input" ? "inputDiagnosticChunks" : "outputDiagnosticChunks";
  if (session[key] >= DIAGNOSTIC_AUDIO_CHUNK_LIMIT) return;
  session[key] += 1;
  diagnostics.record(`${kind}_audio_chunk`, {
    sessionId: session.id,
    chunkIndex: session[key],
    msSinceSessionStart: Date.now() - session.startedAtMs,
    stats: analyzePcm16le(audio, { sampleRate }),
  });
}

function flushAudioCaptures(session, reason) {
  const firstInputWav = session.inputCapture?.flush();
  const firstOutputWav = session.outputCapture?.flush();
  const patch = {};
  if (firstInputWav && firstInputWav !== session.stats.firstInputWav) patch.firstInputWav = firstInputWav;
  if (firstOutputWav && firstOutputWav !== session.stats.firstOutputWav) patch.firstOutputWav = firstOutputWav;
  if (!Object.keys(patch).length) return;
  updateSessionStats(session, patch);
  diagnostics.record("audio_capture_flushed", {
    sessionId: session.id,
    reason,
    firstInputWav: session.stats.firstInputWav,
    firstOutputWav: session.stats.firstOutputWav,
  });
}

function readBooleanEnv(name, fallback) {
  const value = process.env[name];
  if (value === undefined || value === "") return fallback;
  return value === "true" || value === "1";
}

function resetStartupDiagnostics(session) {
  session.startedAtMs = Date.now();
  session.inputDiagnosticChunks = 0;
  session.outputDiagnosticChunks = 0;
  session.successfulListeningRecorded = false;
  session.captureRun += 1;
  session.inputCapture = makeInputCapture(session.id, session.captureRun);
  session.outputCapture = makeOutputCapture(session.id, session.captureRun);
  updateSessionStats(session, { firstInputWav: "", firstOutputWav: "" });
}

function makeInputCapture(sessionId, run) {
  return new FirstOutputWavCapture({
    enabled: CAPTURE_FIRST_INPUT_WAV,
    captureSeconds: CAPTURE_FIRST_INPUT_SECONDS,
    sampleRate: 16000,
    filenamePrefix: `jp-dub-first-input-${sessionId}-${run}`,
  });
}

function makeOutputCapture(sessionId, run) {
  return new FirstOutputWavCapture({
    enabled: CAPTURE_FIRST_OUTPUT_WAV,
    captureSeconds: CAPTURE_FIRST_OUTPUT_SECONDS,
    sampleRate: 24000,
    filenamePrefix: `jp-dub-first-output-${sessionId}-${run}`,
  });
}
