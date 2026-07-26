const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

test("Start refuses non-real local-server before opening capture", async () => {
  const harness = loadServiceWorkerHarness({
    hasOffscreenDocument: true,
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "legacy_non_real",
      realModeReady: false,
      allowedExtensionOriginConfigured: false,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
  });

  await assert.rejects(
    () => harness.context.startFromActiveTab({ originalVolume: 0.3, japaneseVolume: 0.8 }),
    /local_server_not_real_mode/,
  );
  assert.equal(harness.createdOffscreenDocuments, 0);
  assert.equal(harness.offscreenMessages.length, 0);
});

test("Start passes real mode to the offscreen audio session", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      idleExitSeconds: 600,
      diagnostics: { enabled: true },
    },
  });

  await harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8, targetLanguageCode: "es" });

  assert.equal(harness.createdOffscreenDocuments, 1);
  assert.equal(harness.tabCaptureRequests.length, 1);
  assert.equal(harness.tabCaptureRequests[0].targetTabId, 123);
  assert.equal(harness.offscreenMessages.length, 1);
  assert.equal(harness.offscreenMessages[0].mode, "real");
  assert.equal(harness.offscreenMessages[0].type, "start");
  assert.equal(harness.offscreenMessages[0].streamId, "stream-123");
  assert.equal(harness.offscreenMessages[0].targetLanguageCode, "es");
  assert.equal(harness.offscreenMessages[0].translatedVolume, 0.8);
});

test("Start forwards OpenAI only when its Mimi key and lifetime budget are ready", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      providers: {
        gemini: { configured: true },
        openai: { configured: true },
      },
      openaiBudget: { remainingSeconds: 1680 },
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
  });
  await harness.context.startFromActiveTab({
    provider: "openai",
    targetLanguageCode: "ja",
    originalVolume: 0.3,
    translatedVolume: 0.8,
  });
  assert.equal(harness.offscreenMessages[0].provider, "openai");
  assert.equal(Object.prototype.hasOwnProperty.call(harness.offscreenMessages[0], "apiKey"), false);
});

test("Start migrates a stale xAI provider to Gemini before capture", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      providers: { gemini: { configured: true } },
      preferredProvider: "xai",
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
  });
  await harness.context.startFromActiveTab({ provider: "xai", targetLanguageCode: "ja" });
  assert.equal(harness.offscreenMessages[0].provider, "gemini");
  assert.equal(harness.storageSet.jpDubState.provider, "gemini");
});

test("Start rejects an unknown provider instead of falling back to Gemini", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
  });

  await assert.rejects(
    () => harness.context.startFromActiveTab({ provider: "unknown" }),
    /unsupported_provider/,
  );
  assert.equal(harness.tabCaptureRequests.length, 0);
  assert.equal(harness.offscreenMessages.length, 0);
});

test("duplicate Start while startup is in-flight reuses one capture request", async () => {
  const captureCallbacks = [];
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
    getMediaStreamId: (_options, callback) => {
      captureCallbacks.push(callback);
    },
  });

  const firstStart = harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8 });
  const secondStart = harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8 });
  await waitFor(() => captureCallbacks.length > 0);

  assert.equal(harness.tabCaptureRequests.length, 1);
  captureCallbacks.forEach((callback) => callback("stream-123"));
  await Promise.all([firstStart, secondStart]);
  assert.equal(harness.offscreenMessages.filter((message) => message.type === "start").length, 1);
});

test("Start stops a stale offscreen capture before requesting a new stream", async () => {
  const harness = loadServiceWorkerHarness({
    hasOffscreenDocument: true,
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
  });

  await harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8 });

  assert.deepEqual(harness.offscreenMessages.map((message) => message.type), ["stop", "start"]);
  assert.equal(harness.offscreenMessages[0].reason, "start_recovery");
  assert.ok(harness.events.indexOf("offscreen:stop") < harness.events.indexOf("tabCapture"));
  assert.ok(harness.events.indexOf("tabCapture") < harness.events.indexOf("offscreen:start"));
});

test("Start waits for stale offscreen async cleanup before requesting a new capture stream", async () => {
  const offscreen = loadOffscreenStopCleanupHarness();
  const harness = loadServiceWorkerHarness({
    hasOffscreenDocument: true,
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
    offscreenStopHandler: offscreen.handleStop,
  });

  const start = harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8 });
  await waitFor(() => harness.events.includes("offscreen:stop"));
  assert.equal(harness.events.includes("tabCapture"), false);

  offscreen.finishClose();
  await start;
  assert.ok(harness.events.indexOf("audioContext:close-done") < harness.events.indexOf("tabCapture"));
});

test("active-stream tabCapture failure stores safe actionable diagnostics", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
    tabCaptureError: "Can't capture a tab with an active stream",
  });

  await assert.rejects(
    () => harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8 }),
    /capture_active_stream/,
  );

  assert.equal(harness.storageSet.jpDubState.error, "capture_active_stream");
  assert.equal(harness.storageSet.jpDubLatestDiagnostic.code, "capture_active_stream");
  assert.equal(harness.storageSet.jpDubLatestDiagnostic.stage, "capture_stream");
  assert.match(harness.storageSet.jpDubLatestDiagnostic.detail, /Mimi\/Chrome/);
  assert.match(harness.storageSet.jpDubLatestDiagnostic.detail, /停止してもう一度開始/);
  assert.doesNotMatch(JSON.stringify(harness.storageSet.jpDubLatestDiagnostic), /stream-123|active stream/i);
  assert.equal(harness.storageSet.jpDubDiagnostics.length, 1);
});

test("get_status hydrates the latest persisted diagnostic after worker restart", async () => {
  const latestDiagnostic = {
    timestamp: "2026-07-09T00:00:00.000Z",
    stage: "capture_stream",
    code: "capture_active_stream",
    detail: "Mimi/Chrome がこのタブの音声をすでに取得しています。Mimiを停止してもう一度開始してください。",
  };
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
    storageSet: {
      jpDubLatestDiagnostic: latestDiagnostic,
    },
  });

  const response = await harness.context.handleMessage({ type: "get_status" });

  assert.equal(response.state.latestDiagnostic.code, latestDiagnostic.code);
  assert.equal(response.state.latestDiagnostic.stage, latestDiagnostic.stage);
  assert.match(response.state.latestDiagnostic.detail, /Chromeを再起動/);
});

test("get_status removes stale xAI readiness from client state and falls back to Gemini", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      preferredProvider: "xai",
      providers: { gemini: { configured: true }, xai: { configured: true } },
      diagnostics: { enabled: false },
    },
  });

  const response = await harness.context.handleMessage({ type: "get_status" });
  assert.equal(response.state.preferredProvider, "gemini");
  assert.equal(response.state.provider, "gemini");
  assert.equal(Object.prototype.hasOwnProperty.call(response.state, "xaiApiKey"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(response.state, "xaiBudget"), false);
  assert.deepEqual(Object.keys(response.state.providers), ["gemini"]);
});

test("stale Gemini access-denied diagnostics do not force healthy status back to error", async () => {
  const latestDiagnostic = {
    timestamp: "2026-07-09T05:40:59.644Z",
    stage: "gemini",
    code: "gemini_project_access_denied",
    detail: "Google/AI Studio が現在のGemini APIキーまたはプロジェクトを拒否しています。",
  };
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
    storageSet: {
      jpDubLatestDiagnostic: latestDiagnostic,
    },
  });

  harness.context.updateState({ status: "idle", error: "none", lastStopReason: "" });
  const response = await harness.context.handleMessage({ type: "get_status" });

  assert.equal(response.state.status, "idle");
  assert.equal(response.state.error, "none");
  assert.equal(response.state.lastStopReason, "");
  assert.equal(response.state.latestDiagnostic.code, "gemini_project_access_denied");
  assert.equal(harness.storageSet.jpDubState.error, "none");
  assert.equal(harness.storageSet.jpDubState.lastStopReason, "");
});

test("offscreen diagnostics are sanitized before persistent storage", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
  });

  await harness.context.handleMessage({
    target: "service-worker",
    type: "status_event",
    patch: {
      status: "error",
      error: "gemini_project_access_denied",
      latestDiagnostic: {
        timestamp: "2026-07-09T00:00:00.000Z",
        stage: "gemini",
        code: "gemini_project_access_denied",
        detail: "Your project has been denied access. key=abcdef https://example.com/?secret=1 transcript: private words stream-123",
      },
    },
  });

  assert.equal(harness.storageSet.jpDubLatestDiagnostic.code, "gemini_project_access_denied");
  assert.match(harness.storageSet.jpDubLatestDiagnostic.detail, /Google\/AI Studio/);
  assert.match(harness.storageSet.jpDubState.latestDiagnostic.detail, /Gemini APIキー/);
  assert.doesNotMatch(
    JSON.stringify(harness.storageSet),
    /abcdef|example\.com|\?secret=1|private words|stream-123|project has been denied access/i,
  );
});

test("legacy network_error project-denied diagnostics are reclassified before storage", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
  });

  await harness.context.handleMessage({
    target: "service-worker",
    type: "status_event",
    patch: {
      status: "error",
      error: "network_error",
      lastStopReason: "network_error",
      latestDiagnostic: {
        timestamp: "2026-07-09T05:40:59.644Z",
        stage: "gemini",
        code: "network_error",
        detail: "close_1008:Your project has been denied access. Please contact support.",
      },
    },
  });

  assert.equal(harness.storageSet.jpDubState.error, "gemini_project_access_denied");
  assert.equal(harness.storageSet.jpDubState.lastStopReason, "gemini_project_access_denied");
  assert.equal(harness.storageSet.jpDubLatestDiagnostic.code, "gemini_project_access_denied");
  assert.match(harness.storageSet.jpDubLatestDiagnostic.detail, /Google\/AI Studio/);
  assert.doesNotMatch(JSON.stringify(harness.storageSet), /network_error|Your project has been denied access|close_1008/i);
});

test("copy_diagnostics returns bounded redacted diagnostic JSON", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
    storageSet: {
      jpDubDiagnostics: Array.from({ length: 12 }, (_, index) => ({
        timestamp: `2026-07-09T00:00:${String(index).padStart(2, "0")}.000Z`,
        stage: index === 1 ? "gemini" : "capture_stream",
        code: index === 0 ? "capture_active_stream" : index === 1 ? "gemini_project_access_denied" : "startup_failed",
        detail: index === 0
          ? "Can't capture a tab with an active stream stream-123 https://example.com/watch?v=secret AIzaSyDUMMYSECRET transcript: private words password=secret"
          : index === 1
            ? "Your project has been denied access. Please contact support. key=abcdef https://example.com/?secret=1"
          : `safe detail ${index}`,
        streamId: "stream-123",
        url: "https://example.com/watch?v=secret",
        apiKey: "AIzaSyDUMMYSECRET",
      })),
      jpDubState: {
        status: "error",
        error: "capture_active_stream",
        transcript: "private transcript",
        pageUrl: "https://example.com/watch?v=secret",
        geminiApiKey: "AIzaSyDUMMYSECRET",
        streamId: "stream-123",
      },
    },
  });

  const response = await harness.context.handleMessage({ type: "copy_diagnostics" });
  const parsed = JSON.parse(response.text);

  assert.equal(response.ok, true);
  assert.equal(parsed.diagnostics.length, 10);
  assert.equal(parsed.diagnostics[0].code, "capture_active_stream");
  assert.match(parsed.diagnostics[0].detail, /Mimi\/Chrome/);
  assert.equal(parsed.diagnostics[1].code, "gemini_project_access_denied");
  assert.match(parsed.diagnostics[1].detail, /Google\/AI Studio/);
  assert.match(parsed.diagnostics[1].detail, /Gemini APIキー/);
  assert.equal(parsed.state.status, "error");
  assert.equal(parsed.state.error, "capture_active_stream");
  assert.equal(parsed.state.transcript, undefined);
  assert.doesNotMatch(response.text, /Can't capture a tab with an active stream/i);
  assert.doesNotMatch(response.text, /stream-123/);
  assert.doesNotMatch(response.text, /example\.com|watch\?v=secret|\?secret=1/);
  assert.doesNotMatch(response.text, /AIza|password|private transcript|private words/i);
});

test("copy_diagnostics reclassifies legacy network_error project-denied payloads", async () => {
  const legacyDiagnostic = {
    timestamp: "2026-07-09T05:40:59.644Z",
    stage: "gemini",
    code: "network_error",
    detail: "close_1008:Your project has been denied access. Please contact support.",
  };
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: false },
    },
    storageSet: {
      jpDubState: {
        status: "error",
        error: "network_error",
        lastStopReason: "network_error",
        targetLanguageCode: "ja",
        latestDiagnostic: legacyDiagnostic,
      },
      jpDubLatestDiagnostic: legacyDiagnostic,
      jpDubDiagnostics: [legacyDiagnostic],
    },
  });

  const response = await harness.context.handleMessage({ type: "copy_diagnostics" });
  const parsed = JSON.parse(response.text);

  assert.equal(parsed.state.error, "gemini_project_access_denied");
  assert.equal(parsed.state.lastStopReason, "gemini_project_access_denied");
  assert.equal(parsed.state.latestDiagnostic.code, "gemini_project_access_denied");
  assert.equal(parsed.latestDiagnostic.code, "gemini_project_access_denied");
  assert.equal(parsed.diagnostics[0].code, "gemini_project_access_denied");
  assert.match(response.text, /Google\/AI Studio/);
  assert.doesNotMatch(response.text, /network_error|Your project has been denied access|close_1008/i);
});

test("Start reuses a ready real local server when diagnostics are disabled by default", async () => {
  const readyStatus = {
    ok: true,
    service: "jp-dub-local-server",
    mode: "real",
    realModeReady: true,
    allowedExtensionOriginConfigured: true,
    allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    idleExitSeconds: 600,
    diagnostics: { enabled: false },
  };
  const harness = loadServiceWorkerHarness({
    statuses: [readyStatus],
  });

  await harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8 });

  assert.deepEqual(harness.nativeMessages.map((message) => message.type), []);
  assert.equal(harness.offscreenMessages.length, 1);
});

test("Restart Server & Start stops capture, force-starts native server, then starts active tab", async () => {
  const readyStatus = {
    ok: true,
    service: "jp-dub-local-server",
    mode: "real",
    realModeReady: true,
    allowedExtensionOriginConfigured: true,
    allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    idleExitSeconds: 600,
    diagnostics: { enabled: true },
  };
  const harness = loadServiceWorkerHarness({
    hasOffscreenDocument: true,
    statuses: [readyStatus, readyStatus],
  });

  await harness.context.restartAndStartFromActiveTab({
    originalVolume: 0.2,
    translatedVolume: 0.9,
    targetLanguageCode: "fr",
  });

  assert.deepEqual(harness.nativeMessages.map((message) => message.type), ["stop_server", "ensure_server"]);
  assert.equal(harness.nativeMessages[1].diagnostics, false);
  assert.equal(harness.nativeMessages[1].idleExitSeconds, 600);
  assert.equal(harness.tabCaptureRequests.length, 1);
  assert.equal(harness.tabCaptureRequests[0].targetTabId, 123);
  assert.deepEqual(harness.offscreenMessages.map((message) => message.type), ["stop", "start"]);
  assert.equal(harness.offscreenMessages[0].reason, "restart_server");
  assert.equal(harness.offscreenMessages[1].mode, "real");
  assert.equal(harness.offscreenMessages[1].streamId, "stream-123");
  assert.equal(harness.offscreenMessages[1].targetLanguageCode, "fr");
  assert.equal(harness.offscreenMessages[1].translatedVolume, 0.9);
});

test("status patches without mode cannot clear real mode", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: true },
    },
  });

  harness.context.updateState({ status: "connected", mode: undefined });
  const response = await harness.context.handleMessage({ type: "get_status" });

  assert.equal(response.state.mode, "real");
});

test("Stop leaves native-managed server running so diagnostics status stays reachable", async () => {
  const harness = loadServiceWorkerHarness({
    hasOffscreenDocument: true,
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: true },
    },
  });
  harness.context.updateState({ status: "translating", serverManagedByNative: true });

  await harness.context.stopSession();

  assert.deepEqual(harness.nativeMessages, []);
  assert.equal(harness.offscreenMessages[0].type, "stop");
  const response = await harness.context.handleMessage({ type: "get_status" });
  assert.equal(response.state.status, "idle");
});

test("API key settings opens the local server settings page without sending a key", async () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: false,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      diagnostics: { enabled: true },
    },
  });

  await harness.context.handleMessage({ type: "open_key_settings" });

  assert.equal(harness.openedTabs.length, 1);
  assert.equal(harness.openedTabs[0].url, "http://127.0.0.1:8787/settings");
  assert.deepEqual(harness.nativeMessages, []);
});

test("safety recovery actions clear stale monthly-limit stop reasons", async () => {
  const readyStatus = {
    ok: true,
    service: "jp-dub-local-server",
    mode: "real",
    realModeReady: false,
    allowedExtensionOriginConfigured: true,
    allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    diagnostics: { enabled: true },
  };
  const recoveredBilling = { monthlyLimitEnabled: true, remainingSeconds: 2700, limitSeconds: 2700, usedSeconds: 0 };
  const harness = loadServiceWorkerHarness({
    status: readyStatus,
    fetch: async (_url, init = {}) => ({
      ok: true,
      json: async () => (init.method === "POST" ? { ok: true, billing: recoveredBilling } : readyStatus),
    }),
  });

  harness.context.updateState({
    status: "idle",
    error: "none",
    lastStopReason: "monthly_limit_reached",
    billing: { monthlyLimitEnabled: true, remainingSeconds: 0, limitSeconds: 3600, usedSeconds: 3600 },
  });

  const reset = await harness.context.handleMessage({ type: "reset_usage" });
  assert.equal(reset.state.lastStopReason, "");
  assert.equal(reset.state.error, "none");
  assert.equal(reset.state.billing.remainingSeconds, 2700);

  harness.context.updateState({ lastStopReason: "monthly_limit_reached" });
  const limit = await harness.context.handleMessage({ type: "set_limit", monthlyLimitEnabled: true, limitMinutes: 45 });
  assert.equal(limit.state.lastStopReason, "");
  assert.equal(limit.state.error, "none");
  assert.equal(limit.state.billing.monthlyLimitEnabled, true);
  assert.equal(limit.state.billing.limitSeconds, 2700);
});

test("Start restarts a real server with the wrong allowed extension id", async () => {
  const wrongStatus = {
    ok: true,
    service: "jp-dub-local-server",
    mode: "real",
    realModeReady: true,
    allowedExtensionOriginConfigured: true,
    allowedExtensionId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    idleExitSeconds: 600,
    diagnostics: { enabled: false },
  };
  const readyStatus = {
    ...wrongStatus,
    allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  };
  const harness = loadServiceWorkerHarness({
    statuses: [wrongStatus, readyStatus],
  });

  await harness.context.startFromActiveTab({ originalVolume: 0.3, translatedVolume: 0.8 });

  assert.deepEqual(harness.nativeMessages.map((message) => message.type), ["stop_server", "ensure_server"]);
  assert.equal(harness.nativeMessages[1].expectedExtensionId, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  assert.equal(harness.offscreenMessages.length, 1);
});

test("server readiness rejects a wrong allowed extension id", () => {
  const harness = loadServiceWorkerHarness({
    status: {
      ok: true,
      service: "jp-dub-local-server",
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      diagnostics: { enabled: true },
    },
  });

  assert.throws(
    () => harness.context.assertRealServerReady({
      mode: "real",
      realModeReady: true,
      allowedExtensionOriginConfigured: true,
      allowedExtensionId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    }),
    /extension_origin_mismatch/,
  );
});

test("install event announces the real extension to the local server", async () => {
  const requests = [];
  const harness = loadServiceWorkerHarness({
    fetch: async (url, init = {}) => {
      requests.push({ url, init });
      return {
        ok: true,
        json: async () => ({ ok: true }),
      };
    },
  });

  harness.installedListener();
  await waitFor(() => requests.length === 1);

  assert.equal(requests[0].url, "http://127.0.0.1:8787/extension/ready");
  assert.equal(requests[0].init.method, "POST");
  assert.equal(JSON.parse(requests[0].init.body).extensionId, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
  assert.equal(JSON.parse(requests[0].init.body).isOnToolbar, true);
  assert.equal(JSON.parse(requests[0].init.body).event, "installed");
  assert.match(harness.storageSet.jpDubInstalledAt, /^\d{4}-\d{2}-\d{2}T/);
});

test("toolbar pin changes reannounce automatic completion state", async () => {
  const requests = [];
  const harness = loadServiceWorkerHarness({
    isOnToolbar: true,
    fetch: async (url, init = {}) => {
      requests.push({ url, init });
      return { ok: true, json: async () => ({ ok: true }) };
    },
  });

  harness.userSettingsListener({ isOnToolbar: true });
  await waitFor(() => requests.length === 1);

  assert.equal(JSON.parse(requests[0].init.body).isOnToolbar, true);
  assert.equal(JSON.parse(requests[0].init.body).event, "toolbar_changed");
});

function loadServiceWorkerHarness(options) {
  const filePath = path.resolve(__dirname, "..", "src", "service-worker.js");
  const source = fs.readFileSync(filePath, "utf8");
  const harness = {
    createdOffscreenDocuments: 0,
    events: [],
    nativeMessages: [],
    openedTabs: [],
    offscreenMessages: [],
    storageSet: { ...(options.storageSet || {}) },
    tabCaptureRequests: [],
    installedListener: () => undefined,
    userSettingsListener: () => undefined,
  };
  const statuses = [...(options.statuses || [options.status])];
  const context = {
    AbortController,
    Date,
    Error,
    JSON,
    Math,
    Number,
    Promise,
    clearTimeout,
    fetch: options.fetch || (async (url) => {
      if (String(url).endsWith("/extension/ready")) {
        return { ok: true, json: async () => ({ ok: true }) };
      }
      return {
        ok: true,
        json: async () => statuses.shift() || options.status || statuses.at(-1),
      };
    }),
    setTimeout,
    chrome: {
      action: {
        getUserSettings: async () => ({ isOnToolbar: options.isOnToolbar !== false }),
        onUserSettingsChanged: {
          addListener: (listener) => { harness.userSettingsListener = listener; },
        },
      },
      runtime: {
        id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        getManifest: () => ({ name: "Mimi", version: "0.0.1" }),
        lastError: null,
        onInstalled: { addListener: (listener) => { harness.installedListener = listener; } },
        onMessage: { addListener: () => undefined },
        sendMessage: async (message) => {
          if (message?.target === "offscreen") {
            harness.offscreenMessages.push(message);
            harness.events.push(`offscreen:${message.type}`);
            if (message.type === "stop" && options.offscreenStopHandler) return options.offscreenStopHandler(message);
          }
          return { ok: true };
        },
        sendNativeMessage: (_hostName, message, callback) => {
          harness.nativeMessages.push(message);
          callback({ ok: true });
        },
      },
      storage: {
        local: {
          get: async (key) => {
            if (typeof key === "string") return { [key]: harness.storageSet[key] };
            if (Array.isArray(key)) {
              return Object.fromEntries(key.map((name) => [name, harness.storageSet[name]]));
            }
            return {};
          },
          set: async (value) => {
            Object.assign(harness.storageSet, value);
          },
        },
      },
      offscreen: {
        hasDocument: async () => Boolean(options.hasOffscreenDocument),
        createDocument: async () => {
          harness.createdOffscreenDocuments += 1;
        },
      },
      tabs: {
        query: async () => [{ id: 123 }],
        create: async (createProperties) => {
          harness.openedTabs.push(createProperties);
        },
      },
      tabCapture: {
        getMediaStreamId: (request, callback) => {
          harness.tabCaptureRequests.push(request);
          harness.events.push("tabCapture");
          if (options.getMediaStreamId) {
            options.getMediaStreamId(request, callback);
            return;
          }
          if (options.tabCaptureError) {
            context.chrome.runtime.lastError = { message: options.tabCaptureError };
            callback();
            context.chrome.runtime.lastError = null;
            return;
          }
          callback(`stream-${request.targetTabId}`);
        },
      },
    },
  };
  vm.runInNewContext(source, context);
  harness.context = context;
  return harness;
}

function loadOffscreenStopCleanupHarness() {
  const filePath = path.resolve(__dirname, "..", "src", "offscreen.js");
  const source = fs.readFileSync(filePath, "utf8");
  let finishClose;
  const events = [];
  const context = {
    AudioContext: class MockAudioContext {
      constructor() {
        this.audioWorklet = { addModule: async () => undefined };
      }

      close() {
        events.push("audioContext:close-start");
        return new Promise((resolve) => {
          finishClose = () => {
            events.push("audioContext:close-done");
            resolve();
          };
        });
      }
    },
    AudioWorkletNode: class {},
    ArrayBuffer,
    DataView,
    Date,
    Float32Array,
    Int16Array,
    JSON,
    Math,
    Number,
    Promise,
    clearTimeout: () => undefined,
    setTimeout: () => ({}),
    WebSocket: class {},
    chrome: {
      runtime: {
        onMessage: { addListener: () => undefined },
        sendMessage: () => ({ catch: () => undefined }),
      },
    },
    navigator: { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) } },
  };
  context.WebSocket.OPEN = 1;
  const sandbox = { ...context, events };
  vm.runInNewContext(`${source}
globalThis.__offscreenTest = {
  activateSession() {
    audioContext = new AudioContext();
    mediaStream = { getTracks: () => [{ stop: () => events.push("track:stop") }] };
    socket = { readyState: WebSocket.OPEN, send: () => undefined, close: () => events.push("socket:close") };
  },
};
`, sandbox);
  sandbox.__offscreenTest.activateSession();
  return {
    finishClose: () => finishClose(),
    handleStop: (message) => sandbox.handleMessage(message),
  };
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  assert.fail("condition was not met");
}
