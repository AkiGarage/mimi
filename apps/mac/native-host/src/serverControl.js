const http = require("http");
const path = require("path");
const { spawnSync } = require("child_process");

const LOCAL_SERVER_DIR = path.resolve(__dirname, "..", "..", "local-server");
const STATUS_TIMEOUT_MS = 900;
const DEFAULT_START_TIMEOUT_MS = 7000;
const DEFAULT_IDLE_EXIT_SECONDS = 600;
const DEFAULT_STOP_TIMEOUT_MS = 4000;

async function status() {
  const port = Number(process.env.JP_DUB_PORT || 8787);
  const value = await fetchStatus(port).catch(() => null);
  return value ? summarizeStatus(value) : { running: false, port };
}

async function ensureServer(options = {}, dependencies = {}) {
  const readStatus = dependencies.status || status;
  const stopExistingServer = dependencies.stopServer || stopServer;
  const startExistingServer = dependencies.startServer || startServer;
  const waitForExistingStatus = dependencies.waitForStatus || waitForStatus;

  const before = await readStatus();
  if (before.running) {
    if (serverMatchesExpectedExtension(before, options.expectedExtensionId)) {
      return { started: false, status: before };
    }
    await stopExistingServer();
  }

  const idleExitSeconds = positiveInteger(options.idleExitSeconds, DEFAULT_IDLE_EXIT_SECONDS);
  const start = startExistingServer({
    diagnostics: options.diagnostics === true,
    idleExitSeconds,
  });
  const started = await waitForExistingStatus(positiveInteger(options.timeoutMs, DEFAULT_START_TIMEOUT_MS));
  if (!serverMatchesExpectedExtension(started, options.expectedExtensionId)) {
    throw new Error("local_server_extension_origin_mismatch");
  }
  return { started: true, start, status: started };
}

async function stopServer() {
  const stop = spawnSync(process.execPath, ["scripts/stop.js"], {
    cwd: LOCAL_SERVER_DIR,
    encoding: "utf8",
    timeout: 5000,
  });
  if (stop.error) throw stop.error;
  await waitForStopped(DEFAULT_STOP_TIMEOUT_MS);
  return {
    stopped: stop.status === 0,
    statusCode: stop.status,
    output: sanitizeProcessOutput(stop.stdout || stop.stderr || ""),
  };
}

function startServer(options = {}) {
  const env = {
    ...process.env,
    JP_DUB_IDLE_EXIT_SECONDS: String(positiveInteger(options.idleExitSeconds, DEFAULT_IDLE_EXIT_SECONDS)),
  };
  if (options.diagnostics) {
    env.JP_DUB_DIAGNOSTICS = "true";
    env.JP_DUB_CAPTURE_FIRST_INPUT_WAV = "true";
    env.JP_DUB_CAPTURE_FIRST_OUTPUT_WAV = "true";
  }
  const start = spawnSync(process.execPath, ["scripts/start-detached.js"], {
    cwd: LOCAL_SERVER_DIR,
    encoding: "utf8",
    env,
    timeout: 5000,
  });
  if (start.error) throw start.error;
  return {
    statusCode: start.status,
    output: sanitizeProcessOutput(start.stdout || start.stderr || ""),
  };
}

async function waitForStatus(timeoutMs) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const value = await status();
    if (value.running) return value;
    await delay(250);
  }
  throw new Error("local_server_start_timeout");
}

async function waitForStopped(timeoutMs) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const value = await status();
    if (!value.running) return;
    await delay(250);
  }
  throw new Error("local_server_stop_timeout");
}

function summarizeStatus(value) {
  return {
    running: value?.ok === true && value?.service === "jp-dub-local-server",
    port: Number(process.env.JP_DUB_PORT || 8787),
    mode: value?.mode || "",
    targetLanguage: value?.targetLanguage || "",
    activeSessions: Number(value?.activeSessions || 0),
    realModeReady: Boolean(value?.realModeReady),
    allowedExtensionOriginConfigured: Boolean(value?.allowedExtensionOriginConfigured),
    allowedExtensionOrigin: value?.allowedExtensionOrigin || "",
    allowedExtensionId: value?.allowedExtensionId || "",
    allowedExtensionOriginSource: value?.allowedExtensionOriginSource || "",
    idleExitSeconds: Number(value?.idleExitSeconds || 0),
    diagnosticsEnabled: Boolean(value?.diagnostics?.enabled),
    diagnosticsLog: value?.diagnostics?.logPath || "",
    captureFirstInputWav: Boolean(value?.diagnostics?.captureFirstInputWav),
    captureFirstOutputWav: Boolean(value?.diagnostics?.captureFirstOutputWav),
  };
}

function serverMatchesExpectedExtension(value, expectedExtensionId) {
  const expected = normalizeExtensionId(expectedExtensionId);
  if (!expected) return true;
  return value?.allowedExtensionId === expected;
}

function normalizeExtensionId(value) {
  const text = String(value || "").trim().toLowerCase();
  return /^[a-p]{32}$/.test(text) ? text : "";
}

function fetchStatus(port) {
  return new Promise((resolve, reject) => {
    const request = http.get(`http://127.0.0.1:${port}/status`, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          reject(new Error(`non_json_status_${response.statusCode}`));
        }
      });
    });
    request.on("error", reject);
    request.setTimeout(STATUS_TIMEOUT_MS, () => {
      request.destroy(new Error("status_timeout"));
    });
  });
}

function sanitizeProcessOutput(value) {
  return String(value).replace(/\s+/g, " ").trim().slice(0, 500);
}

function positiveInteger(value, fallback) {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = {
  DEFAULT_IDLE_EXIT_SECONDS,
  DEFAULT_START_TIMEOUT_MS,
  DEFAULT_STOP_TIMEOUT_MS,
  ensureServer,
  serverMatchesExpectedExtension,
  startServer,
  status,
  stopServer,
  summarizeStatus,
};
