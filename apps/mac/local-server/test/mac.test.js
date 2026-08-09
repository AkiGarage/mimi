const assert = require("node:assert/strict");
const test = require("node:test");
const { BillingGuard, defaultStoragePath, readLocalUsageSummary } = require("../src/billingGuard");
const {
  DEFAULT_MAX_PENDING_AUDIO_CHUNKS,
  GeminiLiveTranslateSession,
  classifyGeminiError,
  makeSetupMessage,
  safeErrorDetail,
} = require("../src/geminiBridge");
const {
  cumulativeUsageDelta,
  estimateAudioTokensFromSeconds,
  estimateLiveTranslateCost,
  maxUsage,
  normalizeUsageMetadata,
} = require("../src/usageAccounting");
const { localEnvPath, parseEnvLine } = require("../src/localEnv");
const { normalizeTargetLanguageCode } = require("../src/languages");
const { makeOriginPolicy } = require("../src/originPolicy");
const { attachWebSocketServer } = require("../src/websocket");
const { FirstOutputWavCapture, makeWavBuffer } = require("../src/audioDebug");
const { DiagnosticsLog, analyzePcm16le } = require("../src/diagnostics");
const {
  DEFAULT_KEYCHAIN_ACCOUNT,
  DEFAULT_KEYCHAIN_SERVICE,
  geminiApiKeyStatus,
  keychainHelperPath,
  makeGeminiApiKeyStatusCache,
  resolveGeminiApiKey,
  saveGeminiApiKey,
} = require("../src/secrets");
const { normalizeLimitMinutes, updateMonthlyLimitEnabled, updateMonthlyLimitMinutes } = require("../src/settings");
const {
  SetupProgressStore,
  markListeningStartedFromAudio,
  tryMarkListeningStarted,
} = require("../src/setupProgress");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const WebSocketClient = require("ws");
const {
  CANONICAL_EXTENSION_ID,
  CANONICAL_EXTENSION_ORIGIN,
  resolveExtensionOrigin,
} = require("../../shared/extensionOrigin.cjs");
const {
  isLikelyMimiLocalServerCommand,
  isMimiLocalServerProcess,
} = require("../scripts/start-detached");
const { isSafePidForStop, waitForStopped } = require("../scripts/stop");
const { collectDebug, redactString } = require("../scripts/collect-debug");

test("billing guard enforces monthly limit", () => {
  const guard = new BillingGuard(2);
  assert.equal(guard.snapshot().monthlyLimitEnabled, true);
  assert.equal(guard.canUse(1), true);
  guard.record(1);
  assert.equal(guard.canUse(1), true);
  guard.record(1);
  assert.equal(guard.canUse(1), false);
  assert.equal(guard.snapshot().remainingSeconds, 0);
});

test("billing guard does not cap free-key default monthly usage", () => {
  const guard = new BillingGuard({ limitSeconds: 2, monthlyLimitEnabled: false, storagePath: null });

  guard.record(120);

  const snapshot = guard.snapshot();
  assert.equal(snapshot.monthlyLimitEnabled, false);
  assert.equal(snapshot.usedSeconds, 120);
  assert.equal(snapshot.remainingSeconds, null);
  assert.equal(guard.canUse(3600), true);
});

test("setup progress store persists the latest successful listening start without secrets", () => {
  const root = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `setup-progress-unit-${process.pid}`);
  const progressPath = path.join(root, "mimi-setup-progress.json");
  fs.rmSync(root, { recursive: true, force: true });
  try {
    const store = new SetupProgressStore(progressPath);
    assert.equal(store.snapshot().listeningStarted, false);
    assert.equal(store.snapshot().listeningStartedAt, null);

    const snapshot = store.markListeningStarted(new Date("2026-07-13T01:00:00.000Z"));
    assert.equal(snapshot.listeningStarted, true);
    assert.equal(snapshot.listeningStartedAt, "2026-07-13T01:00:00.000Z");

    const restarted = store.markListeningStarted(new Date("2026-07-13T02:00:00.000Z"));
    assert.equal(restarted.listeningStarted, true);
    assert.equal(restarted.listeningStartedAt, "2026-07-13T02:00:00.000Z");

    const reloaded = new SetupProgressStore(progressPath);
    assert.deepEqual(reloaded.snapshot(), restarted);
    assert.doesNotMatch(fs.readFileSync(progressPath, "utf8"), /dummy-local-test-value|transcript|audio|https?:\/\//);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("setup progress write failure does not interrupt successful translation status", () => {
  const store = {
    markListeningStarted() {
      const error = new Error("read-only storage");
      error.code = "EROFS";
      throw error;
    },
  };
  let recordedCode = null;

  const marked = tryMarkListeningStarted(store, (error) => {
    recordedCode = error.code;
  });

  assert.equal(marked, false);
  assert.equal(recordedCode, "EROFS");
});

test("translation status and errors cannot complete setup before translated audio arrives", () => {
  const session = { successfulListeningRecorded: false };
  let writes = 0;
  const store = {
    markListeningStarted() {
      writes += 1;
    },
  };

  assert.equal(markListeningStartedFromAudio(session, Buffer.alloc(0), store), false);
  assert.equal(writes, 0);
  assert.equal(session.successfulListeningRecorded, false);

  assert.equal(markListeningStartedFromAudio(session, Buffer.from([1, 0]), store), true);
  assert.equal(writes, 1);
  assert.equal(session.successfulListeningRecorded, true);

  assert.equal(markListeningStartedFromAudio(session, Buffer.from([2, 0]), store), false);
  assert.equal(writes, 1);
});

test("billing guard preserves existing paid monthly limits without enabled flag", () => {
  const guard = new BillingGuard({
    env: { JP_DUB_MONTHLY_LIMIT_MINUTES: "2" },
    storagePath: null,
  });

  guard.record(120);

  assert.equal(guard.snapshot().monthlyLimitEnabled, true);
  assert.equal(guard.canUse(1), false);
});

test("billing guard keeps old free-tier setup monthly limits disabled without enabled flag", () => {
  const guard = new BillingGuard({
    env: { JP_DUB_FREE_TIER_MODE: "true", JP_DUB_MONTHLY_LIMIT_MINUTES: "2" },
    storagePath: null,
  });

  guard.record(120);

  assert.equal(guard.snapshot().monthlyLimitEnabled, false);
  assert.equal(guard.canUse(3600), true);
});

test("billing guard persists monthly usage and token totals", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `usage-test-${process.pid}.json`);
  fs.rmSync(filePath, { force: true });
  const guard = new BillingGuard({ limitSeconds: 60, storagePath: filePath });
  guard.record(12);
  guard.recordOutput(8);
  guard.recordTokens({ inputTokens: 1000, outputTokens: 2000, totalTokens: 3000 });
  guard.flush();
  const restored = new BillingGuard({ limitSeconds: 60, storagePath: filePath });
  assert.equal(restored.snapshot().usedSeconds, 12);
  assert.equal(restored.snapshot().outputSeconds, 8);
  assert.equal(restored.snapshot().usage.inputTokens, 1000);
  assert.equal(restored.snapshot().usage.outputTokens, 2000);
  fs.rmSync(filePath, { force: true });
});

test("billing guard supports limit updates and local usage reset", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `usage-reset-${process.pid}.json`);
  fs.rmSync(filePath, { force: true });
  const guard = new BillingGuard({ limitSeconds: 120, storagePath: filePath });
  guard.record(90);

  guard.setLimitSeconds(60);

  assert.equal(guard.snapshot().limitSeconds, 60);
  assert.equal(guard.snapshot().usedSeconds, 90);
  assert.equal(guard.snapshot().remainingSeconds, 0);

  guard.setLimitSeconds(120);

  assert.equal(guard.snapshot().limitSeconds, 120);
  assert.equal(guard.snapshot().usedSeconds, 90);
  assert.equal(guard.snapshot().remainingSeconds, 30);
  const backupPath = guard.resetUsage();
  const snapshot = guard.snapshot();
  assert.equal(snapshot.usedSeconds, 0);
  assert.equal(snapshot.outputSeconds, 0);
  assert.equal(fs.existsSync(backupPath), true);
  assert.equal(fs.existsSync(filePath), true);
  fs.rmSync(filePath, { force: true });
  fs.rmSync(backupPath, { force: true });
});

test("local usage summary detects exhausted local safety limit", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `usage-summary-${process.pid}.json`);
  fs.rmSync(filePath, { force: true });
  fs.writeFileSync(filePath, JSON.stringify({
    version: 1,
    month: new Date().toISOString().slice(0, 7),
    limitSeconds: 60,
    usedSeconds: 60,
    outputSeconds: 12,
    inputTokens: 1,
    outputTokens: 2,
    totalTokens: 3,
    updatedAt: new Date().toISOString(),
  }));

  const summary = readLocalUsageSummary({ storagePath: filePath, monthlyLimitEnabled: true, limitSeconds: 60 });

  assert.equal(summary.exists, true);
  assert.equal(summary.usedSeconds, 60);
  assert.equal(summary.limitSeconds, 60);
  assert.equal(summary.remainingSeconds, 0);
  assert.equal(summary.state, "exhausted");
  fs.rmSync(filePath, { force: true });
});

test("local usage summary is disabled by default for free-key users", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `usage-summary-disabled-${process.pid}.json`);
  fs.rmSync(filePath, { force: true });

  const summary = readLocalUsageSummary({ storagePath: filePath, env: {} });

  assert.equal(summary.monthlyLimitEnabled, false);
  assert.equal(summary.state, "disabled");
  assert.equal(summary.remainingSeconds, null);
});

test("billing guard storage path can be redirected for app bundles", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `usage-env-${process.pid}.json`);
  const previous = process.env.JP_DUB_USAGE_FILE;
  process.env.JP_DUB_USAGE_FILE = filePath;
  try {
    assert.equal(defaultStoragePath(), filePath);
    const guard = new BillingGuard({ limitSeconds: 60 });
    guard.record(10);
    guard.flush();
    assert.equal(fs.existsSync(filePath), true);
  } finally {
    if (previous === undefined) {
      delete process.env.JP_DUB_USAGE_FILE;
    } else {
      process.env.JP_DUB_USAGE_FILE = previous;
    }
    fs.rmSync(filePath, { force: true });
  }
});

test("Gemini setup uses Japanese live translation audio config", () => {
  const setup = makeSetupMessage({ targetLanguageCode: "ja" });
  assert.equal(setup.setup.model, "models/gemini-3.5-live-translate-preview");
  assert.deepEqual(setup.setup.generationConfig.responseModalities, ["AUDIO"]);
  assert.equal(setup.setup.generationConfig.translationConfig.targetLanguageCode, "ja");
  assert.equal(setup.setup.generationConfig.translationConfig.echoTargetLanguage, false);
  assert.equal("inputAudioTranscription" in setup.setup, false);
  assert.deepEqual(setup.setup.outputAudioTranscription, {});
  assert.equal("inputAudioTranscription" in setup.setup.generationConfig, false);
});

test("Gemini setup only echoes target language when explicitly enabled", () => {
  const setup = makeSetupMessage({ targetLanguageCode: "ja", echoTargetLanguage: true });
  assert.equal(setup.setup.generationConfig.translationConfig.echoTargetLanguage, true);
});

test("Gemini setup accepts supported non-Japanese target languages", () => {
  const setup = makeSetupMessage({ targetLanguageCode: "es", echoTargetLanguage: true });
  assert.equal(setup.setup.generationConfig.translationConfig.targetLanguageCode, "es");
});

test("target language guard accepts supported Live API codes only", () => {
  assert.equal(normalizeTargetLanguageCode("JA"), "ja");
  assert.equal(normalizeTargetLanguageCode("ceb"), "ceb");
  assert.equal(normalizeTargetLanguageCode("xx", "ja"), "");
});

test("Gemini bridge ignores input transcripts and forwards only translated output transcripts", () => {
  const transcripts = [];
  const session = new GeminiLiveTranslateSession({
    callbacks: {
      onTranscript: (value) => transcripts.push(value),
    },
  });
  session.handleServerContent({
    inputTranscription: { text: "hello world", languageCode: "en" },
    outputTranscription: { text: "こんにちは", languageCode: "ja" },
  });
  assert.deepEqual(transcripts, [{ kind: "output", text: "こんにちは", languageCode: "ja" }]);
});

test("Gemini startup queue keeps only recent audio chunks", () => {
  assert.equal(DEFAULT_MAX_PENDING_AUDIO_CHUNKS, 6);
  const session = new GeminiLiveTranslateSession({ maxPendingAudioChunks: 3 });
  session.queueAudio(Buffer.from([1]));
  session.queueAudio(Buffer.from([2]));
  session.queueAudio(Buffer.from([3]));
  session.queueAudio(Buffer.from([4]));
  assert.deepEqual(session.pendingAudio.map((chunk) => chunk[0]), [2, 3, 4]);
});

test("Gemini setup flushes recent startup audio when the session becomes ready", () => {
  const statuses = [];
  const sent = [];
  const session = new GeminiLiveTranslateSession({
    callbacks: {
      onStatus: (status) => statuses.push(status),
      onInputAudioSent: (byteLength) => sent.push(byteLength),
    },
  });
  session.socket = {
    readyState: WebSocket.OPEN,
    send: (value) => sent.push(value),
  };
  session.queueAudio(Buffer.from([1, 2, 3]));

  session.handleSetupComplete();

  assert.deepEqual(statuses, ["translating"]);
  assert.deepEqual(session.pendingAudio, []);
  assert.equal(sent.length, 2);
  assert.equal(JSON.parse(sent[0]).realtimeInput.audio.data, "AQID");
  assert.equal(sent[1], 3);
});

test("Gemini audio send callback fires only for actually sent chunks", () => {
  let sentBytes = 0;
  const session = new GeminiLiveTranslateSession({
    callbacks: {
      shouldSendAudio: (audio) => audio[0] !== 9,
      onInputAudioSent: (byteLength) => {
        sentBytes += byteLength;
      },
    },
  });
  session.ready = true;
  session.socket = {
    readyState: WebSocket.OPEN,
    send: () => {},
  };
  assert.equal(session.sendAudio(Buffer.from([1, 2, 3])), true);
  assert.equal(session.sendAudio(Buffer.from([9, 2, 3])), false);
  assert.equal(sentBytes, 3);
});

test("first output wav capture writes bounded 24kHz PCM diagnostics", () => {
  const outputDir = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `wav-capture-test-${process.pid}`);
  fs.rmSync(outputDir, { recursive: true, force: true });
  const capture = new FirstOutputWavCapture({
    enabled: true,
    captureSeconds: 1,
    outputDir,
  });
  const pcm = Buffer.alloc(24000 * 2);
  const filePath = capture.addAudio(pcm);

  assert.ok(filePath.endsWith(".wav"));
  const wav = fs.readFileSync(filePath);
  assert.equal(wav.toString("ascii", 0, 4), "RIFF");
  assert.equal(wav.toString("ascii", 8, 12), "WAVE");
  assert.equal(wav.readUInt32LE(24), 24000);
  assert.equal(wav.readUInt32LE(40), pcm.length);
  fs.rmSync(outputDir, { recursive: true, force: true });
});

test("first output wav capture flushes partial audio on stop", () => {
  const outputDir = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `wav-flush-test-${process.pid}`);
  fs.rmSync(outputDir, { recursive: true, force: true });
  const capture = new FirstOutputWavCapture({
    enabled: true,
    captureSeconds: 4,
    outputDir,
    filenamePrefix: "partial-output",
  });
  capture.addAudio(Buffer.alloc(2400));
  const filePath = capture.flush();

  assert.ok(filePath.includes("partial-output"));
  const wav = fs.readFileSync(filePath);
  assert.equal(wav.readUInt32LE(40), 2400);
  fs.rmSync(outputDir, { recursive: true, force: true });
});

test("raw WAV capture stays off until diagnostics explicitly opt in", () => {
  const outputDir = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `wav-default-off-${process.pid}`);
  fs.rmSync(outputDir, { recursive: true, force: true });
  const capture = new FirstOutputWavCapture({ outputDir });

  assert.equal(capture.addAudio(Buffer.alloc(24000 * 2)), "");
  assert.equal(capture.flush(), "");
  assert.equal(fs.existsSync(outputDir), false);
});

test("wav buffer header describes raw pcm length", () => {
  const wav = makeWavBuffer(Buffer.alloc(8), { sampleRate: 24000, channels: 1 });
  assert.equal(wav.length, 52);
  assert.equal(wav.readUInt32LE(4), 44);
  assert.equal(wav.readUInt32LE(40), 8);
});

test("diagnostics log writes redacted local events and pcm stats", () => {
  const logPath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `diagnostics-${process.pid}.ndjson`);
  fs.rmSync(logPath, { force: true });
  const diagnostics = new DiagnosticsLog({ logPath });
  const fakeGoogleKey = "AI" + "za123456789012345678901234567890";
  const pcm = Buffer.alloc(8);
  pcm.writeInt16LE(1200, 0);
  pcm.writeInt16LE(-1200, 2);

  diagnostics.record("sample", {
    apiKey: fakeGoogleKey,
    detail: "url key=abcdef12345",
    stats: analyzePcm16le(pcm, { sampleRate: 16000 }),
  });

  const line = fs.readFileSync(logPath, "utf8").trim();
  assert.match(line, /"event":"sample"/);
  assert.doesNotMatch(line, /AIza/);
  assert.doesNotMatch(line, /abcdef12345/);
  assert.match(line, /"zeroCrossings":1/);
  fs.rmSync(logPath, { force: true });
});

test("debug collection redacts secrets from status logs and environment", async () => {
  const root = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `debug-collect-${process.pid}`);
  const outputDir = path.join(root, "bundle");
  const fakeGoogleKey = ["AI", "za", "123456789012345678901234567890"].join("");
  const keyField = ["api", "Key"].join("");
  const tokenField = ["to", "ken"].join("");
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(path.join(root, "logs"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "logs", "jp-dub-local-server.log"),
    `token=abc123 ${fakeGoogleKey} host=${os.hostname()}\n`,
  );
  fs.writeFileSync(path.join(root, "logs", "jp-dub-diagnostics.ndjson"), `{"${keyField}":"${fakeGoogleKey}"}\n`);
  fs.mkdirSync(path.join(root, "tmp"), { recursive: true });
  fs.writeFileSync(path.join(root, "tmp", "jp-dub-usage.json"), `${JSON.stringify({ usedSeconds: 1 })}\n`);

  await collectDebug({
    root,
    outputDir,
    env: { JP_DUB_PORT: "8787", GEMINI_API_KEY: fakeGoogleKey },
    fetchStatus: async () => ({
      ok: true,
      [keyField]: fakeGoogleKey,
      diagnostics: { logPath: "/Users/private-user/Library/Mimi/private.ndjson" },
      nested: {
        [tokenField]: "abc123",
        pageUrl: "https://private.example/watch?id=private",
        message: `diagnostic from ${os.hostname()}`,
      },
    }),
  });

  const combined = fs.readdirSync(outputDir)
    .map((name) => fs.readFileSync(path.join(outputDir, name), "utf8"))
    .join("\n");
  assert.doesNotMatch(combined, /AIza/);
  assert.doesNotMatch(combined, /abc123/);
  assert.doesNotMatch(combined, /private-user|private\.example|debug-collect-/);
  assert.doesNotMatch(combined, new RegExp(os.hostname().replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i"));
  assert.match(combined, /\[redacted\]/);
  fs.rmSync(root, { recursive: true, force: true });
});

test("debug redaction handles common secret shapes", () => {
  const fakeGoogleKey = ["AI", "za", "123456789012345678901234567890"].join("");
  const text = redactString(`authorization=abc Bearer xyz key=secret ${fakeGoogleKey}`);
  assert.doesNotMatch(text, /abc|xyz|secret|AIza/);
  assert.match(text, /\[redacted\]/);
});

test("usage metadata deltas and live translate cost are calculated from token totals", () => {
  const first = normalizeUsageMetadata({
    promptTokenCount: 250,
    responseTokensDetails: [{ modality: "AUDIO", tokenCount: 500 }],
    totalTokenCount: 750,
  });
  const second = normalizeUsageMetadata({
    promptTokenCount: 300,
    responseTokensDetails: [{ modality: "AUDIO", tokenCount: 600 }],
    totalTokenCount: 900,
  });
  assert.deepEqual(cumulativeUsageDelta(first, second), {
    inputTokens: 50,
    outputTokens: 100,
    totalTokens: 150,
    unknownTokens: 0,
  });
  const cost = estimateLiveTranslateCost(second, 160);
  assert.equal(cost.totalUsd, 0.01365);
  assert.equal(cost.totalJpy, 2.184);
});

test("live audio token estimate uses 25 tokens per second", () => {
  assert.deepEqual(estimateAudioTokensFromSeconds(2, 3), {
    inputTokens: 50,
    outputTokens: 75,
    totalTokens: 125,
    unknownTokens: 0,
  });
  assert.deepEqual(maxUsage({ inputTokens: 10, outputTokens: 100, totalTokens: 110 }, { inputTokens: 50, outputTokens: 40, totalTokens: 90 }), {
    inputTokens: 50,
    outputTokens: 100,
    totalTokens: 150,
    unknownTokens: 0,
  });
});

test("Gemini quota and auth errors are classified as stop reasons", () => {
  assert.equal(classifyGeminiError("RESOURCE_EXHAUSTED quota exceeded"), "quota_or_free_tier_error");
  assert.equal(classifyGeminiError("API key invalid"), "auth_error");
  assert.equal(classifyGeminiError("403 PERMISSION_DENIED Your project has been denied access. Please contact support."), "gemini_project_access_denied");
  assert.equal(classifyGeminiError("INVALID_ARGUMENT bad request"), "invalid_request");
});

test("Gemini error detail is redacted", () => {
  assert.equal(safeErrorDetail("bad url key=abcdef12345"), "bad url REDACTED_KEY_FIELD");
  assert.doesNotMatch(
    safeErrorDetail("403 PERMISSION_DENIED Your project has been denied access. key=abcdef12345 https://example.com/?secret=1"),
    /abcdef12345|example\.com|\?secret=1/,
  );
});

test("local env parser reads quoted values without exposing actual env files", () => {
  const keyName = "GEMINI_" + "API_KEY";
  const dummyValue = "abc" + "123";
  assert.deepEqual(parseEnvLine(`${keyName}='${dummyValue}'`), [keyName, dummyValue]);
  assert.deepEqual(parseEnvLine(`export ${keyName}=${dummyValue}`), [keyName, dummyValue]);
  assert.equal(parseEnvLine("# comment"), null);
});

test("local env path can be redirected for app bundles", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `mimi-env-${process.pid}.env`);
  const previous = process.env.JP_DUB_ENV_FILE;
  process.env.JP_DUB_ENV_FILE = filePath;
  try {
    assert.equal(localEnvPath(), filePath);
  } finally {
    if (previous === undefined) {
      delete process.env.JP_DUB_ENV_FILE;
    } else {
      process.env.JP_DUB_ENV_FILE = previous;
    }
  }
});

test("monthly limit setting updates local env without touching secrets", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `mimi-settings-${process.pid}.env`);
  fs.rmSync(filePath, { force: true });
  fs.writeFileSync(filePath, "GEMINI_API_KEY=developer-fallback\nJP_DUB_MONTHLY_LIMIT_MINUTES=30\n");

  const minutes = updateMonthlyLimitMinutes("45", { filePath });
  const content = fs.readFileSync(filePath, "utf8");

  assert.equal(minutes, 45);
  assert.match(content, /JP_DUB_MONTHLY_LIMIT_ENABLED=true/);
  assert.match(content, /JP_DUB_MONTHLY_LIMIT_MINUTES=45/);
  assert.match(content, /GEMINI_API_KEY=developer-fallback/);
  assert.equal(normalizeLimitMinutes(2000), 1440);
  fs.rmSync(filePath, { force: true });
});

test("monthly limit setting can be disabled without touching secrets", () => {
  const filePath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `mimi-settings-disabled-${process.pid}.env`);
  fs.rmSync(filePath, { force: true });
  fs.writeFileSync(filePath, "GEMINI_API_KEY=developer-fallback\nJP_DUB_MONTHLY_LIMIT_ENABLED=true\nJP_DUB_MONTHLY_LIMIT_MINUTES=30\n");

  const enabled = updateMonthlyLimitEnabled(false, { filePath });
  const content = fs.readFileSync(filePath, "utf8");

  assert.equal(enabled, false);
  assert.match(content, /JP_DUB_MONTHLY_LIMIT_ENABLED=false/);
  assert.match(content, /JP_DUB_MONTHLY_LIMIT_MINUTES=30/);
  assert.match(content, /GEMINI_API_KEY=developer-fallback/);
  fs.rmSync(filePath, { force: true });
});

test("Gemini secret resolver prefers developer env fallback over Keychain", () => {
  const apiKeyName = ["GEMINI", "API", "KEY"].join("_");
  let keychainReads = 0;
  const resolved = resolveGeminiApiKey({
    env: { [apiKeyName]: " env-secret \n" },
    execFileSync: () => {
      keychainReads += 1;
      return "keychain-secret\n";
    },
    platform: "darwin",
  });

  assert.equal(resolved.value, "env-secret");
  assert.equal(resolved.source, "env");
  assert.equal(keychainReads, 0);
});

test("Gemini secret resolver reads macOS Keychain when env fallback is absent", () => {
  const calls = [];
  const resolved = resolveGeminiApiKey({
    env: {},
    execFileSync: (file, args) => {
      calls.push([file, args]);
      return "keychain-secret\n";
    },
    platform: "darwin",
  });

  assert.equal(resolved.value, "keychain-secret");
  assert.equal(resolved.source, "keychain");
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "/usr/bin/security");
  assert.deepEqual(calls[0][1], [
    "find-generic-password",
    "-s",
    DEFAULT_KEYCHAIN_SERVICE,
    "-a",
    DEFAULT_KEYCHAIN_ACCOUNT,
    "-w",
  ]);
});

test("Gemini secret status never returns the key value", () => {
  const status = geminiApiKeyStatus({
    env: {},
    execFileSync: () => "keychain-secret\n",
    platform: "darwin",
  });

  assert.deepEqual(status, {
    configured: true,
    canReplace: false,
    source: "keychain",
    keychainEnabled: true,
    keychainService: DEFAULT_KEYCHAIN_SERVICE,
    keychainAccount: DEFAULT_KEYCHAIN_ACCOUNT,
  });
  assert.equal("value" in status, false);
});

test("Gemini secret status cache avoids repeated Keychain reads", () => {
  let keychainReads = 0;
  const cache = makeGeminiApiKeyStatusCache({
    ttlMs: 1000,
    statusOptions: {
      env: {},
      execFileSync: () => {
        keychainReads += 1;
        return "keychain-secret\n";
      },
      platform: "darwin",
    },
  });

  assert.equal(cache.get({ now: 100 }).configured, true);
  assert.equal(cache.get({ now: 500 }).configured, true);
  assert.equal(keychainReads, 1);

  assert.equal(cache.get({ now: 1200 }).configured, true);
  assert.equal(keychainReads, 2);

  cache.clear();
  assert.equal(cache.get({ now: 1300 }).configured, true);
  assert.equal(keychainReads, 3);
});

test("Gemini API key replacement writes Keychain and returns non-secret status", () => {
  const calls = [];
  const status = saveGeminiApiKey(" new-key \n", {
    env: { JP_DUB_KEYCHAIN_HELPER: "/tmp/mimi-keychain-helper" },
    execFileSync: (file, args, options) => {
      calls.push([file, args, options]);
      if (args[0] === "find-generic-password") return "new-key\n";
      return "";
    },
    platform: "darwin",
  });

  assert.equal(calls.length, 2);
  assert.equal(calls[0][0], "/tmp/mimi-keychain-helper");
  assert.equal(calls[0][1][0], "--save-api-key-stdin");
  assert.equal(calls[0][1].at(-2), DEFAULT_KEYCHAIN_SERVICE);
  assert.equal(calls[0][1].at(-1), DEFAULT_KEYCHAIN_ACCOUNT);
  assert.equal(calls[0][1].includes("new-key"), false);
  assert.equal(calls[0][2].input, "new-key");
  assert.equal(calls[1][0], "/usr/bin/security");
  assert.equal(status.configured, true);
  assert.equal(status.source, "keychain");
  assert.equal("value" in status, false);
});

test("Keychain helper treats service and account metacharacters as inert argv", () => {
  const calls = [];
  const service = "Mimi; touch should-not-run";
  const account = "$(should-not-run)";
  saveGeminiApiKey("new-key", {
    env: { JP_DUB_KEYCHAIN_HELPER: "/tmp/mimi-keychain-helper" },
    execFileSync: (file, args) => {
      calls.push({ file, args });
      return args[0] === "find-generic-password" ? "new-key\n" : "";
    },
    keychainService: service,
    keychainAccount: account,
    platform: "darwin",
  });

  assert.deepEqual(calls[0].args, ["--save-api-key-stdin", service, account]);
  assert.deepEqual(calls[1].args.slice(0, 5), ["find-generic-password", "-s", service, "-a", account]);
});

test("Gemini API key replacement requires a packaged Keychain helper", () => {
  assert.equal(keychainHelperPath({}), "");
  assert.throws(
    () => saveGeminiApiKey("new-key", { env: {}, platform: "darwin" }),
    /keychain_helper_unavailable/,
  );
});

test("Gemini secret resolver does not invoke Keychain when disabled", () => {
  let keychainReads = 0;
  const resolved = resolveGeminiApiKey({
    env: { JP_DUB_USE_KEYCHAIN: "false" },
    execFileSync: () => {
      keychainReads += 1;
      return "keychain-secret\n";
    },
    platform: "darwin",
  });

  assert.equal(resolved.value, "");
  assert.equal(resolved.source, "missing");
  assert.equal(resolved.keychainEnabled, false);
  assert.equal(keychainReads, 0);
});

test("local websocket rejects arbitrary browser origins", async () => {
  const server = http.createServer();
  attachWebSocketServer(server, {
    path: "/ws",
    isAllowedOrigin: (origin) => !origin || origin.startsWith("chrome-extension://"),
    onConnection: () => {},
  });
  await listen(server);
  const port = server.address().port;
  const response = await rawUpgrade(port, "https://example.com");
  server.close();
  assert.match(response, /^HTTP\/1\.1 403 Forbidden/);
});

test("local websocket answers a client close with a bounded normal close frame", async () => {
  const server = http.createServer();
  attachWebSocketServer(server, {
    path: "/ws",
    isAllowedOrigin: () => true,
    onConnection: () => {},
  });
  await listen(server);
  const ws = new WebSocketClient(`ws://127.0.0.1:${server.address().port}/ws`);

  try {
    const result = await new Promise((resolve, reject) => {
      ws.once("error", reject);
      ws.once("close", (code, reason) => resolve({ code, reason: reason.toString() }));
      ws.once("open", () => ws.close(1000, "done"));
    });

    assert.equal(result.code, 1000);
    assert.equal(result.reason, "");
  } finally {
    await closeServer(server);
  }
});

test("real mode requires an explicit extension origin", () => {
  const unconfiguredPolicy = makeOriginPolicy();
  assert.equal(unconfiguredPolicy("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), false);
  assert.equal(unconfiguredPolicy(""), false);
  const configuredPolicy = makeOriginPolicy({
    allowedExtensionOrigin: "chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/",
  });
  assert.equal(configuredPolicy("chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), true);
  assert.equal(configuredPolicy("chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), false);
  assert.equal(configuredPolicy(""), false);
});

test("fixed Mimi extension origin can be derived without user paste", () => {
  const manifestPath = path.resolve(__dirname, "..", "..", "extension", "manifest.json");
  assert.equal(resolveExtensionOrigin({ env: {}, manifestPath }), CANONICAL_EXTENSION_ORIGIN);
});

test("canonical extension origin is accepted exactly and unrelated origins are rejected", () => {
  const policy = makeOriginPolicy({ allowedExtensionOrigin: `${CANONICAL_EXTENSION_ORIGIN}/` });
  assert.equal(policy(CANONICAL_EXTENSION_ORIGIN), true);
  assert.equal(policy(`${CANONICAL_EXTENSION_ORIGIN}/`), true);
  assert.equal(policy(`chrome-extension://${CANONICAL_EXTENSION_ID.slice(0, -1)}a`), false);
  assert.equal(policy("https://example.com"), false);
  assert.equal(policy(""), false);
});

test("status exposes non-secret allowed extension identity", async () => {
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const root = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `status-identity-${process.pid}`);
  const progressPath = path.join(root, "mimi-setup-progress.json");
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  fs.rmSync(root, { recursive: true, force: true });
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_PORT: String(port),
    JP_DUB_SETUP_PROGRESS_FILE: progressPath,
    JP_DUB_SKIP_DOTENV: "1",
  });

  try {
    const status = await waitForServerStatus(port);
    assert.equal(status.allowedExtensionOriginConfigured, true);
    assert.equal(status.allowedExtensionOrigin, origin);
    assert.equal(status.allowedExtensionId, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    assert.equal(status.allowedExtensionOriginSource, "env");
    assert.equal(status.extensionConnection.verified, false);
    assert.equal(status.extensionConnection.lastSeenAt, null);
    assert.equal(status.extensionConnection.isOnToolbar, false);
    assert.equal(status.extensionConnection.installedAt, null);
    assert.equal(status.extensionConnection.toolbarChangedAt, null);
    assert.equal(status.extensionConnection.popupOpenedAt, null);
    assert.equal(status.setupProgress.listeningStarted, false);
    assert.equal(status.setupProgress.listeningStartedAt, null);

    const unrelatedStatus = await fetchJson(`http://127.0.0.1:${port}/status`, {
      headers: { origin: "chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    });
    assert.equal(unrelatedStatus.extensionConnection.verified, false);

    const wrongReady = await postJson(`http://127.0.0.1:${port}/extension/ready`, {
      origin,
      body: { extensionId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    });
    assert.equal(wrongReady.statusCode, 403);
    assert.equal(wrongReady.body.error, "extension_id_not_allowed");

    const missingOriginReady = await postJson(`http://127.0.0.1:${port}/extension/ready`, {
      body: { extensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
    });
    assert.equal(missingOriginReady.statusCode, 403);
    assert.equal(missingOriginReady.body.error, "origin_not_allowed");

    const installed = await postJson(`http://127.0.0.1:${port}/extension/ready`, {
      origin,
      body: { extensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", isOnToolbar: false, event: "installed" },
    });
    assert.equal(installed.statusCode, 200);
    assert.match(installed.body.extensionConnection.installedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.equal(installed.body.extensionConnection.toolbarChangedAt, null);

    const pinned = await postJson(`http://127.0.0.1:${port}/extension/ready`, {
      origin,
      body: { extensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", isOnToolbar: true, event: "toolbar_changed" },
    });
    assert.equal(pinned.statusCode, 200);
    assert.match(pinned.body.extensionConnection.toolbarChangedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.equal(pinned.body.extensionConnection.popupOpenedAt, null);

    const ready = await postJson(`http://127.0.0.1:${port}/extension/ready`, {
      origin,
      body: { extensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", isOnToolbar: true, event: "popup_opened" },
    });
    assert.equal(ready.statusCode, 200);
    assert.match(ready.body.extensionConnection.popupOpenedAt, /^\d{4}-\d{2}-\d{2}T/);

    const extensionStatus = await fetchJson(`http://127.0.0.1:${port}/status`);
    assert.equal(extensionStatus.extensionConnection.verified, true);
    assert.equal(extensionStatus.extensionConnection.isOnToolbar, true);
    assert.match(extensionStatus.extensionConnection.lastSeenAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.match(extensionStatus.extensionConnection.installedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.match(extensionStatus.extensionConnection.toolbarChangedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.match(extensionStatus.extensionConnection.popupOpenedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.doesNotMatch(JSON.stringify(status), /dummy-local-test-value/);
  } finally {
    stopLocalServerProcess(serverProcess);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("preinstalled pinned extension becomes ready when the user opens Mimi", async () => {
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const root = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `status-preinstalled-${process.pid}`);
  const progressPath = path.join(root, "mimi-setup-progress.json");
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  fs.rmSync(root, { recursive: true, force: true });
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_PORT: String(port),
    JP_DUB_SETUP_PROGRESS_FILE: progressPath,
    JP_DUB_SKIP_DOTENV: "1",
  });

  try {
    await waitForServerStatus(port);

    const ready = await postJson(`http://127.0.0.1:${port}/extension/ready`, {
      origin,
      body: { extensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", isOnToolbar: true, event: "popup_opened" },
    });

    assert.equal(ready.statusCode, 200);
    assert.equal(ready.body.extensionConnection.verified, true);
    assert.equal(ready.body.extensionConnection.isOnToolbar, true);
    assert.match(ready.body.extensionConnection.installedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.match(ready.body.extensionConnection.toolbarChangedAt, /^\d{4}-\d{2}-\d{2}T/);
    assert.match(ready.body.extensionConnection.popupOpenedAt, /^\d{4}-\d{2}-\d{2}T/);
  } finally {
    stopLocalServerProcess(serverProcess);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("local server settings endpoints enforce extension origin and expose no secrets", async () => {
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const root = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `settings-endpoints-${process.pid}`);
  const envPath = path.join(root, ".env");
  const usagePath = path.join(root, "jp-dub-usage.json");
  const providerPreferencePath = path.join(root, "provider-preference.json");
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(usagePath, `${JSON.stringify({
    version: 1,
    month: new Date().toISOString().slice(0, 7),
    limitSeconds: 1800,
    usedSeconds: 120,
    outputSeconds: 30,
    inputTokens: 1,
    outputTokens: 2,
    totalTokens: 3,
    updatedAt: new Date().toISOString(),
  })}\n`);
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_ENV_FILE: envPath,
    JP_DUB_PORT: String(port),
    JP_DUB_PROVIDER_PREFERENCE_FILE: providerPreferencePath,
    JP_DUB_SKIP_DOTENV: "1",
    JP_DUB_USAGE_FILE: usagePath,
  });

  try {
    const initial = await waitForServerStatus(port);
    assert.equal(initial.billing.monthlyLimitEnabled, false);
    assert.equal(initial.billing.usedSeconds, 120);
    assert.equal(initial.billing.remainingSeconds, null);
    assert.equal(initial.preferredProvider, "gemini");
    const page = await fetchTextResponse(`http://127.0.0.1:${port}/settings`);
    assert.equal(page.headers["x-frame-options"], "DENY");
    assert.equal(page.headers["content-security-policy"], "frame-ancestors 'none'");
    assert.match(page.body, /Mimi Settings/);
    assert.match(page.body, /Mimi Setup\.command/);
    assert.match(page.body, /Finder/);
    assert.doesNotMatch(page.body, /dummy-local-test-value/);

    const rejected = await postJson(`http://127.0.0.1:${port}/settings/limit`, {
      body: { limitMinutes: 5 },
      origin: "https://example.com",
    });
    assert.equal(rejected.statusCode, 403);
    assert.equal(rejected.body.error, "origin_not_allowed");

    const limit = await postJson(`http://127.0.0.1:${port}/settings/limit`, {
      body: { limitMinutes: 5 },
      origin: `http://127.0.0.1:${port}`,
    });
    assert.equal(limit.statusCode, 200);
    assert.equal(limit.body.billing.monthlyLimitEnabled, true);
    assert.equal(limit.body.billing.limitSeconds, 300);
    assert.match(fs.readFileSync(envPath, "utf8"), /JP_DUB_MONTHLY_LIMIT_MINUTES=5/);
    assert.match(fs.readFileSync(envPath, "utf8"), /JP_DUB_MONTHLY_LIMIT_ENABLED=true/);

    const provider = await postJson(`http://127.0.0.1:${port}/settings/provider`, {
      body: { provider: "openai" },
      origin,
    });
    assert.equal(provider.statusCode, 200);
    assert.equal(provider.body.preferredProvider, "openai");
    assert.equal(JSON.parse(fs.readFileSync(providerPreferencePath, "utf8")).provider, "openai");

    const providerStatus = await waitForServerStatus(port);
    assert.equal(providerStatus.preferredProvider, "openai");

    const rejectedProvider = await postJson(`http://127.0.0.1:${port}/settings/provider`, {
      body: { provider: "unknown" },
      origin,
    });
    assert.equal(rejectedProvider.statusCode, 400);
    assert.equal(rejectedProvider.body.error, "unsupported_provider");

    const removedXaiProvider = await postJson(`http://127.0.0.1:${port}/settings/provider`, {
      body: { provider: "xai" },
      origin,
    });
    assert.equal(removedXaiProvider.statusCode, 400);
    assert.equal(removedXaiProvider.body.error, "unsupported_provider");

    const removedXaiKey = await postJson(`http://127.0.0.1:${port}/settings/api-key`, {
      body: { provider: "xai", apiKey: "not-used" },
      origin,
    });
    assert.equal(removedXaiKey.statusCode, 400);
    assert.equal(removedXaiKey.body.error, "unsupported_provider");

    const extensionLimit = await postJson(`http://127.0.0.1:${port}/settings/limit`, {
      body: { limitMinutes: 45 },
      origin,
    });
    assert.equal(extensionLimit.statusCode, 200);
    assert.equal(extensionLimit.body.billing.limitSeconds, 2700);
    assert.match(fs.readFileSync(envPath, "utf8"), /JP_DUB_MONTHLY_LIMIT_MINUTES=45/);

    const reset = await postJson(`http://127.0.0.1:${port}/settings/usage/reset`, { body: {}, origin });
    assert.equal(reset.statusCode, 200);
    assert.equal(reset.body.billing.usedSeconds, 0);
    assert.equal(reset.body.billing.outputSeconds, 0);
    assert.equal(reset.body.reset.backupCreated, true);
    assert.doesNotMatch(JSON.stringify(reset.body), /dummy-local-test-value/);
  } finally {
    stopLocalServerProcess(serverProcess);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("provider preference is locked while a session is active", async () => {
  const fakeGemini = await startFakeGeminiServer();
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  const root = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `provider-lock-${process.pid}`);
  const envPath = path.join(root, ".env");
  const providerPreferencePath = path.join(root, "provider-preference.json");
  fs.rmSync(root, { recursive: true, force: true });
  fs.mkdirSync(root, { recursive: true });
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_ENV_FILE: envPath,
    JP_DUB_GEMINI_ENDPOINT: `ws://127.0.0.1:${fakeGemini.address().port}/ws`,
    JP_DUB_PORT: String(port),
    JP_DUB_PROVIDER_PREFERENCE_FILE: providerPreferencePath,
    JP_DUB_SKIP_DOTENV: "1",
  });

  try {
    await waitForServerStatus(port);
    const client = await rawWebSocketClient(port, origin);
    assert.equal(JSON.parse(await client.nextText()).status, "connected");
    client.sendText({ type: "start", mode: "real", targetLanguageCode: "ja", provider: "gemini" });
    await waitForServerStatusValue(port, (value) => value.sessions.some((session) => session.started));

    const locked = await postJson(`http://127.0.0.1:${port}/settings/provider`, {
      body: { provider: "openai" },
      origin,
    });
    assert.equal(locked.statusCode, 400);
    assert.equal(locked.body.error, "active_session_provider_locked");
    assert.equal((await waitForServerStatus(port)).preferredProvider, "gemini");
    assert.equal(fs.existsSync(providerPreferencePath), false);

    client.sendText({ type: "stop", reason: "test_complete" });
    client.close();
  } finally {
    await stopLocalServerProcessAndWait(serverProcess);
    fakeGemini.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("detached restart only trusts a Mimi local-server pid", () => {
  const serverCwd = path.resolve(__dirname, "..");
  assert.equal(isLikelyMimiLocalServerCommand(`${process.execPath} src/server.js`), true);
  assert.equal(isLikelyMimiLocalServerCommand("/usr/bin/python src/server.js"), false);

  const execFileSync = (command, args) => {
    if (command === "ps") return `${process.execPath} src/server.js\n`;
    if (command === "lsof") return `p${args[2]}\nn${serverCwd}\n`;
    throw new Error(`unexpected command: ${command}`);
  };
  assert.equal(isMimiLocalServerProcess(123, { execFileSync, serverCwd }), true);
  assert.equal(isSafePidForStop(123, { execFileSync, serverCwd }), true);

  const wrongCwd = (command) => {
    if (command === "ps") return `${process.execPath} src/server.js\n`;
    if (command === "lsof") return "p123\nn/tmp/unrelated\n";
    throw new Error(`unexpected command: ${command}`);
  };
  assert.equal(isMimiLocalServerProcess(123, { execFileSync: wrongCwd, serverCwd }), false);
  assert.equal(isSafePidForStop(123, { execFileSync: wrongCwd, serverCwd }), false);
});

test("local server stop waits until the old Mimi listener is gone", async () => {
  let reads = 0;
  await waitForStopped({
    delay: async () => {},
    fetchStatus: async () => {
      reads += 1;
      return reads === 1 ? { ok: true, service: "jp-dub-local-server" } : null;
    },
    pollMs: 0,
    timeoutMs: 1000,
  });

  assert.equal(reads, 2);
});

test("diagnostic scripts can pass against a fake Gemini endpoint", async () => {
  const fakeGemini = await startFakeGeminiServer();
  const endpoint = `ws://127.0.0.1:${fakeGemini.address().port}/ws`;
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  const env = {
    ...process.env,
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_GEMINI_ENDPOINT: endpoint,
    JP_DUB_SKIP_DOTENV: "1",
  };
  const real = await runNodeScript(["scripts/diagnose-real.js"], { env });
  assert.equal(real.code, 0, real.output);
  assert.match(real.output, /PASS setup_complete/);

  const pcmPath = path.resolve(__dirname, "..", "..", "..", "..", "tmp", `diagnose-stream-${process.pid}.pcm`);
  fs.mkdirSync(path.dirname(pcmPath), { recursive: true });
  fs.writeFileSync(pcmPath, Buffer.alloc(16000 * 2 / 10));
  const stream = await runNodeScript(["scripts/diagnose-stream.js", pcmPath], { env, timeoutMs: 8000 });
  assert.equal(stream.code, 0, stream.output);
  assert.match(stream.output, /PASS stream/);
  assert.match(stream.output, /"outputBytes":[1-9]/);
  fs.rmSync(pcmPath, { force: true });
  await closeServer(fakeGemini);
});

test("local server reconnects real sessions before the configured interval", async () => {
  const fakeGemini = await startFakeGeminiServer();
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_GEMINI_ENDPOINT: `ws://127.0.0.1:${fakeGemini.address().port}/ws`,
    JP_DUB_PORT: String(port),
    JP_DUB_RECONNECT_SECONDS: "1",
    JP_DUB_SKIP_DOTENV: "1",
  });

  try {
    await waitForServerStatus(port);
    const client = await rawWebSocketClient(port, origin);
    const initial = JSON.parse(await client.nextText());
    assert.equal(initial.status, "connected");
    client.sendText({ type: "start", mode: "real", targetLanguageCode: "ja" });

    const statuses = [];
    const deadline = Date.now() + 7000;
    while (Date.now() < deadline) {
      const text = await client.nextText(deadline - Date.now()).catch((error) => {
        throw new Error(`${error.message}; statuses=${statuses.join(",")}; server=${serverProcess.output}`);
      });
      const message = JSON.parse(text);
      if (message.type !== "status") continue;
      statuses.push(message.status);
      const reconnectIndex = statuses.indexOf("reconnecting");
      if (reconnectIndex >= 0 && statuses.slice(reconnectIndex + 1).includes("translating")) break;
    }

    const reconnectIndex = statuses.indexOf("reconnecting");
    assert.ok(statuses.includes("translating"), `statuses=${statuses.join(",")}`);
    assert.ok(reconnectIndex >= 0, `statuses=${statuses.join(",")}`);
    assert.ok(statuses.slice(reconnectIndex + 1).includes("translating"), `statuses=${statuses.join(",")}`);
    client.close();
  } finally {
    stopLocalServerProcess(serverProcess);
    await closeServer(fakeGemini);
  }
});

test("runtime audio starts only after Start and user Stop halts the session", async () => {
  const fakeGemini = await startFakeGeminiServer();
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_GEMINI_ENDPOINT: `ws://127.0.0.1:${fakeGemini.address().port}/ws`,
    JP_DUB_PORT: String(port),
    JP_DUB_SKIP_DOTENV: "1",
  });

  try {
    await waitForServerStatus(port);
    const client = await rawWebSocketClient(port, origin);
    JSON.parse(await client.nextText());
    client.sendBinary(Buffer.alloc(3200));
    const before = await waitForServerStatus(port);
    assert.equal(before.sessions[0].capturedInputBytes, 0);

    client.sendText({ type: "start", mode: "real", targetLanguageCode: "ja" });
    await waitForTextMessage(client, (message) => message.status === "translating");
    client.sendBinary(Buffer.alloc(3200));
    const active = await waitForServerStatusValue(port, (value) => value.sessions[0]?.capturedInputBytes === 3200);
    assert.equal(active.sessions[0].started, true);

    client.sendText({ type: "stop", reason: "user_stopped" });
    const stopped = await waitForServerStatusValue(port, (value) => value.sessions[0]?.lastReason === "user_stopped");
    assert.equal(stopped.sessions[0].started, false);
    client.close();
  } finally {
    stopLocalServerProcess(serverProcess);
    await closeServer(fakeGemini);
  }
});

test("runtime local safety limit stops capture and returns a stable error", async () => {
  const fakeGemini = await startFakeGeminiServer();
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_GEMINI_ENDPOINT: `ws://127.0.0.1:${fakeGemini.address().port}/ws`,
    JP_DUB_MONTHLY_LIMIT_ENABLED: "true",
    JP_DUB_MONTHLY_LIMIT_MINUTES: "0.02",
    JP_DUB_PORT: String(port),
    JP_DUB_SKIP_DOTENV: "1",
    JP_DUB_USAGE_FILE: path.join(os.tmpdir(), `mimi-safety-usage-${process.pid}-${port}.json`),
  });

  try {
    await waitForServerStatus(port);
    const client = await rawWebSocketClient(port, origin);
    JSON.parse(await client.nextText());
    client.sendText({ type: "start", mode: "real", targetLanguageCode: "ja" });
    await waitForTextMessage(client, (message) => message.status === "translating");
    client.sendBinary(Buffer.alloc(32000));
    client.sendBinary(Buffer.alloc(32000));
    const error = await waitForTextMessage(client, (message) => message.type === "error");
    assert.equal(error.error, "monthly_limit_reached");
    const stopped = await waitForServerStatusValue(port, (value) => value.sessions[0]?.lastReason === "monthly_limit_reached");
    assert.equal(stopped.sessions[0].started, false);
    client.close();
  } finally {
    stopLocalServerProcess(serverProcess);
    await closeServer(fakeGemini);
  }
});

test("Gemini project access denial is sent as stable safe error", async () => {
  const fakeGemini = await startDeniedGeminiServer();
  const port = await getFreePort();
  const origin = "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");
  const serverProcess = startLocalServerProcess({
    [apiKeyEnvName]: "dummy-local-test-value",
    JP_DUB_ALLOWED_EXTENSION_ORIGIN: origin,
    JP_DUB_GEMINI_ENDPOINT: `ws://127.0.0.1:${fakeGemini.address().port}/ws`,
    JP_DUB_PORT: String(port),
    JP_DUB_SKIP_DOTENV: "1",
  });

  try {
    await waitForServerStatus(port);
    const client = await rawWebSocketClient(port, origin);
    JSON.parse(await client.nextText());
    client.sendText({ type: "start", mode: "real", targetLanguageCode: "ja" });

    const messages = [];
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline) {
      const message = JSON.parse(await client.nextText(deadline - Date.now()));
      messages.push(message);
      if (message.type === "error") break;
    }

    const error = messages.find((message) => message.type === "error");
    assert.equal(error?.error, "gemini_project_access_denied");
    assert.match(error.detail, /project has been denied access/i);
    assert.doesNotMatch(JSON.stringify(error), /dummy-local-test-value|key=|example\.com|secret=1/);

    const status = await waitForServerStatusValue(
      port,
      (value) => value.lastSession?.lastErrorCode === "gemini_project_access_denied",
    );
    assert.equal(status.sessions[0]?.lastErrorCode, "gemini_project_access_denied");
    assert.equal(status.lastSession.lastErrorCode, "gemini_project_access_denied");
    assert.match(status.lastSession.lastError, /project has been denied access/i);
    assert.doesNotMatch(JSON.stringify(status.lastSession), /dummy-local-test-value|key=|example\.com|secret=1/);
    client.close();
  } finally {
    stopLocalServerProcess(serverProcess);
    await closeServer(fakeGemini);
  }
});

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
}

function getFreePort() {
  const server = net.createServer();
  return new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

function startFakeGeminiServer() {
  const server = http.createServer();
  attachWebSocketServer(server, {
    path: "/ws",
    isAllowedOrigin: () => true,
    onConnection: (peer) => {
      peer.onMessage((frame) => {
        const message = JSON.parse(frame.payload.toString("utf8"));
        if (message.setup) {
          peer.sendText({ setupComplete: {} });
          return;
        }
        if (message.realtimeInput?.audio?.data) {
          peer.sendText({
            serverContent: {
              outputTranscription: { text: "テスト", languageCode: "ja" },
              modelTurn: {
                parts: [
                  { inlineData: { data: Buffer.alloc(240).toString("base64") } },
                ],
              },
            },
          });
        }
      });
    },
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

function startDeniedGeminiServer() {
  const server = http.createServer();
  attachWebSocketServer(server, {
    path: "/ws",
    isAllowedOrigin: () => true,
    onConnection: (peer) => {
      peer.onMessage((frame) => {
        const message = JSON.parse(frame.payload.toString("utf8"));
        if (!message.setup) return;
        peer.sendText({
          error: {
            code: 403,
            status: "PERMISSION_DENIED",
            message: "Your project has been denied access. Please contact support. key=dummy-local-test-value https://example.com/?secret=1",
          },
        });
      });
    },
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

function closeServer(server) {
  return new Promise((resolve) => server.close(resolve));
}

function runNodeScript(args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, {
      cwd: path.resolve(__dirname, ".."),
      env: options.env || process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`timeout running ${args.join(" ")}`));
    }, options.timeoutMs || 5000);
    child.stdout.on("data", (chunk) => { output += chunk.toString("utf8"); });
    child.stderr.on("data", (chunk) => { output += chunk.toString("utf8"); });
    child.on("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timeout);
      resolve({ code, output });
    });
  });
}

function startLocalServerProcess(env) {
  const child = spawn(process.execPath, ["src/server.js"], {
    cwd: path.resolve(__dirname, ".."),
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.output = "";
  child.stdout.on("data", (chunk) => { child.output += chunk.toString("utf8"); });
  child.stderr.on("data", (chunk) => { child.output += chunk.toString("utf8"); });
  return child;
}

function stopLocalServerProcess(child) {
  if (!child || child.exitCode !== null) return;
  child.kill("SIGTERM");
}

function stopLocalServerProcessAndWait(child) {
  if (!child || child.exitCode !== null) return Promise.resolve();
  return new Promise((resolve) => {
    child.once("close", resolve);
    child.kill("SIGTERM");
  });
}

async function waitForServerStatus(port, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const status = await fetchJson(`http://127.0.0.1:${port}/status`);
      if (status?.service === "jp-dub-local-server") return status;
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`server_status_timeout:${lastError?.message || "no_status"}`);
}

async function waitForServerStatusValue(port, predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let lastStatus = null;
  while (Date.now() < deadline) {
    lastStatus = await fetchJson(`http://127.0.0.1:${port}/status`).catch(() => null);
    if (lastStatus && predicate(lastStatus)) return lastStatus;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`server_status_value_timeout:${JSON.stringify(lastStatus)}`);
}

function fetchJson(url, options = {}) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, { headers: options.headers || {} }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try {
          resolve(JSON.parse(body));
        } catch (error) {
          reject(error);
        }
      });
    });
    request.on("error", reject);
    request.setTimeout(1000, () => request.destroy(new Error("status_timeout")));
  });
}

function fetchText(url) {
  return fetchTextResponse(url).then((response) => response.body);
}

function fetchTextResponse(url) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => resolve({ body, headers: response.headers, statusCode: response.statusCode }));
    });
    request.on("error", reject);
    request.setTimeout(1000, () => request.destroy(new Error("status_timeout")));
  });
}

function postJson(url, options = {}) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(options.body || {});
    const target = new URL(url);
    const request = http.request({
      hostname: target.hostname,
      method: "POST",
      path: target.pathname,
      port: target.port,
      headers: {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
        ...(options.origin ? { origin: options.origin } : {}),
      },
    }, (response) => {
      let responseBody = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { responseBody += chunk; });
      response.on("end", () => {
        try {
          resolve({ statusCode: response.statusCode, body: JSON.parse(responseBody) });
        } catch (error) {
          reject(error);
        }
      });
    });
    request.on("error", reject);
    request.setTimeout(1000, () => request.destroy(new Error("post_timeout")));
    request.end(body);
  });
}

function rawWebSocketClient(port, origin) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port });
    const state = { buffer: Buffer.alloc(0), queue: [], waiters: [] };
    socket.setTimeout(5000);
    socket.on("connect", () => {
      socket.write([
        "GET /ws HTTP/1.1",
        `Host: 127.0.0.1:${port}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        `Origin: ${origin}`,
        "",
        "",
      ].join("\r\n"));
    });
    socket.on("data", (chunk) => handleClientData(state, socket, chunk, resolve, reject));
    socket.on("timeout", () => {
      socket.destroy();
      reject(new Error("websocket_timeout"));
    });
    socket.on("error", reject);
  });
}

function handleClientData(state, socket, chunk, resolve, reject) {
  state.buffer = Buffer.concat([state.buffer, chunk]);
  const handshakeEnd = state.buffer.indexOf("\r\n\r\n");
  if (!state.handshakeComplete) {
    if (handshakeEnd < 0) return;
    const handshake = state.buffer.subarray(0, handshakeEnd).toString("latin1");
    if (!handshake.startsWith("HTTP/1.1 101")) {
      reject(new Error(handshake.split("\r\n")[0]));
      socket.destroy();
      return;
    }
    state.handshakeComplete = true;
    state.buffer = state.buffer.subarray(handshakeEnd + 4);
    resolve(makeRawClient(socket, state));
  }
  parseServerFrames(state);
}

function makeRawClient(socket, state) {
  return {
    sendText(value) {
      socket.write(makeClientFrame(JSON.stringify(value)));
    },
    sendBinary(value) {
      socket.write(makeClientFrame(value, 0x2));
    },
    nextText(timeoutMs = 1000) {
      const found = state.queue.shift();
      if (found !== undefined) return Promise.resolve(found);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("next_text_timeout")), Math.max(1, timeoutMs));
        state.waiters.push({
          resolve: (value) => {
            clearTimeout(timer);
            resolve(value);
          },
        });
      });
    },
    close() {
      socket.destroy();
    },
  };
}

function parseServerFrames(state) {
  while (state.buffer.length >= 2) {
    const parsed = parseServerFrame(state.buffer);
    if (!parsed) return;
    state.buffer = state.buffer.subarray(parsed.nextOffset);
    if (parsed.opcode !== 0x1) continue;
    const text = parsed.payload.toString("utf8");
    const waiter = state.waiters.shift();
    if (waiter) {
      waiter.resolve(text);
    } else {
      state.queue.push(text);
    }
  }
}

function parseServerFrame(buffer) {
  let length = buffer[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    length = Number(buffer.readBigUInt64BE(2));
    offset = 10;
  }
  if (buffer.length < offset + length) return null;
  return {
    opcode: buffer[0] & 0x0f,
    payload: buffer.subarray(offset, offset + length),
    nextOffset: offset + length,
  };
}

function makeClientFrame(value, opcode = 0x1) {
  const payload = Buffer.from(value);
  const mask = Buffer.from([1, 2, 3, 4]);
  const masked = Buffer.alloc(payload.length);
  for (let index = 0; index < payload.length; index += 1) {
    masked[index] = payload[index] ^ mask[index % 4];
  }
  const header = payload.length < 126
    ? Buffer.from([0x80 | opcode, 0x80 | payload.length])
    : makeLongClientHeader(payload.length, opcode);
  return Buffer.concat([header, mask, masked]);
}

function makeLongClientHeader(length, opcode) {
  if (length <= 0xffff) {
    const header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 0x80 | 126;
    header.writeUInt16BE(length, 2);
    return header;
  }
  throw new Error("client_frame_too_large");
}

async function waitForTextMessage(client, predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const message = JSON.parse(await client.nextText(deadline - Date.now()));
    if (predicate(message)) return message;
  }
  throw new Error("message_timeout");
}

function rawUpgrade(port, origin) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: "127.0.0.1", port });
    let response = "";
    socket.setTimeout(2000);
    socket.on("connect", () => {
      socket.write([
        "GET /ws HTTP/1.1",
        `Host: 127.0.0.1:${port}`,
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        `Origin: ${origin}`,
        "",
        "",
      ].join("\r\n"));
    });
    socket.on("data", (chunk) => {
      response += chunk.toString("latin1");
      if (response.includes("\r\n\r\n")) {
        socket.destroy();
        resolve(response);
      }
    });
    socket.on("timeout", () => {
      socket.destroy();
      reject(new Error("timeout"));
    });
    socket.on("error", reject);
  });
}
