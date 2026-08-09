const assert = require("node:assert/strict");
const test = require("node:test");
const path = require("node:path");
const { decodeMessage, encodeMessage } = require("../src/nativeProtocol");
const {
  buildHostManifest,
  HOST_NAME,
  nativeHostWrapperPath,
  normalizeExtensionOrigin,
} = require("../src/hostManifest");
const { ensureServer, serverMatchesExpectedExtension, summarizeStatus } = require("../src/serverControl");
const {
  CANONICAL_EXTENSION_ID,
  CANONICAL_EXTENSION_ORIGIN,
  extensionIdFromManifestKey,
  resolveExtensionOriginDetails,
  resolveExtensionOrigin,
} = require("../../shared/extensionOrigin.cjs");
const { resolveInstallOrigin } = require("../scripts/install");

test("native protocol encodes and decodes JSON frames", () => {
  const frame = encodeMessage({ type: "ping", value: "こんにちは" });
  assert.equal(frame.readUInt32LE(0), frame.length - 4);
  assert.deepEqual(decodeMessage(frame), { type: "ping", value: "こんにちは" });
});

test("native host manifest uses Chrome origin and absolute executable path", () => {
  const hostPath = path.resolve(__dirname, "..", "bin", "jp-dub-native-host.js");
  const manifest = buildHostManifest({
    hostPath,
    extensionOrigin: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  });
  assert.equal(manifest.name, HOST_NAME);
  assert.equal(manifest.path, hostPath);
  assert.equal(manifest.type, "stdio");
  assert.deepEqual(manifest.allowed_origins, ["chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/"]);
});

test("fixed Mimi manifest key derives the expected extension origin", () => {
  const manifestPath = path.resolve(__dirname, "..", "..", "extension", "manifest.json");
  const manifest = require(manifestPath);
  assert.equal(extensionIdFromManifestKey(manifest.key), CANONICAL_EXTENSION_ID);
  assert.equal(resolveExtensionOrigin({ env: {}, manifestPath }), CANONICAL_EXTENSION_ORIGIN);
});

test("explicit extension origin accepts the canonical origin and rejects non-extension origins", () => {
  const explicit = resolveExtensionOriginDetails({
    env: { MIMI_EXTENSION_ORIGIN: `${CANONICAL_EXTENSION_ORIGIN}/` },
  });
  assert.deepEqual(explicit, {
    origin: CANONICAL_EXTENSION_ORIGIN,
    source: "env",
    extensionId: CANONICAL_EXTENSION_ID,
  });
  assert.throws(
    () => resolveExtensionOriginDetails({ env: { MIMI_EXTENSION_ORIGIN: "https://example.com" } }),
    /invalid_extension_origin/,
  );
});

test("extension origin validation rejects non-extension origins", () => {
  assert.throws(() => normalizeExtensionOrigin("https://example.com"), /invalid_extension_origin/);
});

test("native host installer CLI origin overrides invalid env origin", () => {
  const resolved = resolveInstallOrigin(
    ["node", "install.js", "--extension-origin=chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    { MIMI_EXTENSION_ORIGIN: "https://example.com" },
  );
  assert.deepEqual(resolved, {
    origin: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    source: "argument",
  });
});

test("native host wrapper path is user scoped", () => {
  assert.equal(
    nativeHostWrapperPath("/Users/example"),
    "/Users/example/Library/Application Support/JP Dub/NativeHost/jp-dub-native-host",
  );
});

test("server status summary excludes transcripts and raw session data", () => {
  const summary = summarizeStatus({
    ok: true,
    service: "jp-dub-local-server",
    mode: "real",
    targetLanguage: "ja",
    activeSessions: 1,
    realModeReady: true,
    allowedExtensionOriginConfigured: true,
    allowedExtensionOrigin: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    allowedExtensionOriginSource: "env",
    idleExitSeconds: 120,
    diagnostics: {
      enabled: true,
      logPath: "/tmp/jp-dub-diagnostics.ndjson",
      captureFirstInputWav: true,
      captureFirstOutputWav: true,
    },
    lastSession: { outputTranscript: "private text" },
  });
  assert.deepEqual(summary, {
    running: true,
    port: 8787,
    mode: "real",
    targetLanguage: "ja",
    activeSessions: 1,
    realModeReady: true,
    allowedExtensionOriginConfigured: true,
    allowedExtensionOrigin: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    allowedExtensionOriginSource: "env",
    idleExitSeconds: 120,
    diagnosticsEnabled: true,
    diagnosticsLog: "/tmp/jp-dub-diagnostics.ndjson",
    captureFirstInputWav: true,
    captureFirstOutputWav: true,
  });
});

test("server control compares expected allowed extension id", () => {
  assert.equal(serverMatchesExpectedExtension({ allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), true);
  assert.equal(serverMatchesExpectedExtension({ allowedExtensionId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), false);
  assert.equal(serverMatchesExpectedExtension({ allowedExtensionId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }, ""), true);
});

test("ensureServer restarts a wrong-origin existing server", async () => {
  const calls = [];
  const wrongStatus = {
    running: true,
    allowedExtensionId: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  };
  const rightStatus = {
    running: true,
    allowedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  };

  const result = await ensureServer(
    { expectedExtensionId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", idleExitSeconds: 10 },
    {
      status: async () => wrongStatus,
      stopServer: async () => {
        calls.push("stop");
        return { stopped: true };
      },
      startServer: (options) => {
        calls.push(`start:${options.idleExitSeconds}`);
        return { statusCode: 0, output: "" };
      },
      waitForStatus: async () => rightStatus,
    },
  );

  assert.deepEqual(calls, ["stop", "start:10"]);
  assert.equal(result.started, true);
  assert.equal(result.status.allowedExtensionId, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
});
