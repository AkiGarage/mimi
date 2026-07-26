const { loadLocalEnv, localEnvDiagnostics } = require("../src/localEnv");
const { geminiApiKeyStatus, getGeminiApiKey } = require("../src/secrets");
const {
  DEFAULT_ENDPOINT,
  DEFAULT_MODEL,
  DEFAULT_TARGET_LANGUAGE,
  classifyGeminiError,
  makeSetupMessage,
  safeErrorDetail,
} = require("../src/geminiBridge");

loadLocalEnv();

const apiKey = getGeminiApiKey();
const model = process.env.JP_DUB_MODEL || DEFAULT_MODEL;
const targetLanguageCode = process.env.JP_DUB_TARGET_LANGUAGE || DEFAULT_TARGET_LANGUAGE;
const endpoint = process.env.JP_DUB_GEMINI_ENDPOINT || DEFAULT_ENDPOINT;

if (!apiKey) {
  console.error("FAIL missing_api_key: run Mimi Setup or set GEMINI_API_KEY as a developer fallback.");
  const diagnostics = localEnvDiagnostics();
  const secret = geminiApiKeyStatus();
  if (diagnostics.skipped) {
    console.error("Checked local .env: skipped because JP_DUB_SKIP_DOTENV=1");
  } else if (!diagnostics.exists) {
    console.error(`Checked local .env: not found at ${diagnostics.filePath}`);
  } else if (!diagnostics.hasGeminiKeyLine) {
    console.error(`Checked local .env: found at ${diagnostics.filePath}, but no GEMINI_API_KEY line was detected.`);
  } else {
    console.error(`Checked local .env: found GEMINI_API_KEY line at ${diagnostics.filePath}, but it parsed as empty or invalid.`);
  }
  if (secret.keychainEnabled) {
    console.error(`Checked macOS Keychain: no key found for service "${secret.keychainService}" account "${secret.keychainAccount}".`);
  } else {
    console.error("Checked macOS Keychain: disabled or unavailable on this platform.");
  }
  process.exit(1);
}

if (typeof WebSocket === "undefined") {
  console.error("FAIL node_websocket_unavailable: use Node.js 22+ or a runtime with global WebSocket.");
  process.exit(1);
}

const url = `${endpoint}?key=${encodeURIComponent(apiKey)}`;
const socket = new WebSocket(url);
const timeout = setTimeout(() => finish(false, "timeout_waiting_for_setup_complete"), 10000);

socket.addEventListener("open", () => {
  socket.send(JSON.stringify(makeSetupMessage({
    model,
    targetLanguageCode,
    echoTargetLanguage: process.env.JP_DUB_ALLOW_TARGET_LANGUAGE_ECHO === "true",
  })));
});

socket.addEventListener("message", async (event) => {
  const text = await websocketDataToString(event.data);
  const message = safeJsonParse(text);
  if (!message) return;
  if (message.setupComplete) finish(true, `setup_complete model=${model} target=${targetLanguageCode}`);
  if (message.error) {
    finish(false, `${classifyGeminiError(message.error)} ${safeErrorDetail(message.error)}`);
  }
});

socket.addEventListener("error", () => finish(false, "network_error"));
socket.addEventListener("close", (event) => {
  if (event.code !== 1000) {
    finish(false, `${classifyGeminiError(event.reason || `close_${event.code}`)} ${event.reason || `close_${event.code}`}`);
  }
});

async function websocketDataToString(data) {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  if (typeof data?.arrayBuffer === "function") return Buffer.from(await data.arrayBuffer()).toString("utf8");
  return String(data);
}

function safeJsonParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function finish(ok, message) {
  clearTimeout(timeout);
  try {
    socket.close();
  } catch {
    // Ignore close races in the diagnostic path.
  }
  console.log(`${ok ? "PASS" : "FAIL"} ${message}`);
  process.exit(ok ? 0 : 1);
}
