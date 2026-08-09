const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");

const DEFAULT_TAIL_BYTES = 64 * 1024;
const SECRET_KEY_PATTERN = /api.?key|authorization|bearer|credential|gemini|password|secret|token/i;
const LOCAL_METADATA_KEY_PATTERN = /(^|_)(?:file)?path$|hostname|root|pageurl|privateurl|logpath|firstinputwav|firstoutputwav/i;

if (require.main === module) {
  collectDebug().then((result) => {
    console.log(`Mimi debug bundle saved to ${result.outputDir}`);
  }).catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}

async function collectDebug(options = {}) {
  const root = options.root || path.resolve(__dirname, "..", "..", "..", "..");
  const outputDir = options.outputDir || path.join(root, "tmp", "mimi-debug", timestamp());
  const port = Number(options.port || process.env.JP_DUB_PORT || 8787);
  fs.mkdirSync(outputDir, { recursive: true });

  const files = [];
  const status = await readStatus({ port, fetchStatus: options.fetchStatus });
  files.push(writeJson(outputDir, "status.json", redactValue(status)));

  const usagePath = path.join(root, "tmp", "jp-dub-usage.json");
  files.push(writeText(outputDir, "usage.json", readRedactedFile(usagePath, "{\n  \"missing\": true\n}\n")));

  const serverLogPath = path.join(root, "logs", "jp-dub-local-server.log");
  files.push(writeText(outputDir, "local-server.log.tail.txt", readRedactedTail(serverLogPath)));

  const diagnosticsPath = path.join(root, "logs", "jp-dub-diagnostics.ndjson");
  files.push(writeText(outputDir, "diagnostics.ndjson.tail.txt", readRedactedTail(diagnosticsPath)));

  files.push(writeJson(outputDir, "environment-summary.json", makeEnvironmentSummary({
    env: options.env || process.env,
    root,
    port,
  })));

  files.push(writeJson(outputDir, "manifest.json", {
    createdAt: new Date().toISOString(),
    files: files.map((filePath) => path.basename(filePath)),
    notes: [
      "No Keychain values are read.",
      "Secret-like values are redacted before writing.",
      "Diagnostics are collected only if an existing diagnostics log is present.",
    ],
  }));

  return { outputDir, files };
}

async function readStatus(options = {}) {
  if (options.fetchStatus) return options.fetchStatus();
  return new Promise((resolve) => {
    const request = http.get(`http://127.0.0.1:${options.port || 8787}/status`, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          resolve({ ok: false, error: `status returned non-JSON HTTP ${response.statusCode}` });
        }
      });
    });
    request.on("error", (error) => resolve({ ok: false, error: error.message }));
    request.setTimeout(3000, () => {
      request.destroy();
      resolve({ ok: false, error: "status check timed out" });
    });
  });
}

function makeEnvironmentSummary(options = {}) {
  const env = options.env || process.env;
  const safeNames = [
    "JP_DUB_PORT",
    "JP_DUB_MODEL",
    "JP_DUB_TARGET_LANGUAGE",
    "JP_DUB_FREE_TIER_MODE",
    "JP_DUB_SHOW_USAGE_ESTIMATE",
    "JP_DUB_MONTHLY_LIMIT_MINUTES",
    "JP_DUB_ALLOW_TARGET_LANGUAGE_ECHO",
    "JP_DUB_RECONNECT_SECONDS",
    "JP_DUB_DIAGNOSTICS",
    "JP_DUB_CAPTURE_FIRST_INPUT_WAV",
    "JP_DUB_CAPTURE_FIRST_OUTPUT_WAV",
    "JP_DUB_CAPTURE_BROWSER_MIX_WAV",
    "JP_DUB_ALLOWED_EXTENSION_ORIGIN",
  ];
  const values = {};
  for (const name of safeNames) {
    if (Object.prototype.hasOwnProperty.call(env, name)) values[name] = redactString(String(env[name]));
  }
  const redactedVariableNames = Object.keys(env)
    .filter((name) => SECRET_KEY_PATTERN.test(name))
    .sort();
  return {
    createdAt: new Date().toISOString(),
    platform: process.platform,
    arch: process.arch,
    node: process.version,
    localMetadata: "[redacted]",
    statusEndpoint: "loopback-only",
    env: values,
    redactedVariableNames,
  };
}

function readRedactedFile(filePath, fallback) {
  try {
    return redactString(fs.readFileSync(filePath, "utf8"));
  } catch {
    return fallback;
  }
}

function readRedactedTail(filePath) {
  try {
    return redactString(tailFile(filePath, DEFAULT_TAIL_BYTES));
  } catch {
    return "missing\n";
  }
}

function tailFile(filePath, maxBytes) {
  const stat = fs.statSync(filePath);
  const start = Math.max(0, stat.size - maxBytes);
  const handle = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(handle, buffer, 0, buffer.length, start);
    return buffer.toString("utf8");
  } finally {
    fs.closeSync(handle);
  }
}

function writeJson(outputDir, filename, value) {
  return writeText(outputDir, filename, `${JSON.stringify(value, null, 2)}\n`);
}

function writeText(outputDir, filename, value) {
  const filePath = path.join(outputDir, filename);
  fs.writeFileSync(filePath, value, { mode: 0o600 });
  return filePath;
}

function redactValue(value, key = "") {
  if (key && SECRET_KEY_PATTERN.test(key)) return "[redacted]";
  if (key && LOCAL_METADATA_KEY_PATTERN.test(key)) return "[redacted_local_metadata]";
  if (value === null || value === undefined) return value;
  if (Array.isArray(value)) return value.map((item) => redactValue(item));
  if (typeof value === "string") return redactString(value);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value !== "object") return redactString(String(value));
  const output = {};
  for (const [childKey, childValue] of Object.entries(value)) {
    output[childKey] = redactValue(childValue, childKey);
  }
  return output;
}

function redactString(value) {
  const redacted = String(value)
    .replace(/AIza[0-9A-Za-z_-]{20,}/g, "[redacted]")
    .replace(/(key|token|secret|authorization|password)=([^&\s]+)/gi, "$1=[redacted]")
    .replace(/Bearer\s+[0-9A-Za-z._~+/=-]+/gi, "Bearer [redacted]")
    .replace(/https?:\/\/[^\s"')]+/gi, "[redacted_url]")
    .replace(/\/(?:Users|private|tmp|var\/folders)\/[^\s"')]+/g, "[redacted_local_path]");
  const hostname = os.hostname().trim();
  if (!hostname) return redacted;
  return redacted.replace(new RegExp(escapeRegExp(hostname), "gi"), "[redacted_hostname]");
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function timestamp() {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "Z");
}

module.exports = {
  collectDebug,
  makeEnvironmentSummary,
  redactString,
  redactValue,
};
