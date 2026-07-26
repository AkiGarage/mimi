const fs = require("fs");
const path = require("path");
const { loadLocalEnv } = require("../src/localEnv");
const { GeminiLiveTranslateSession } = require("../src/geminiBridge");
const { getGeminiApiKey } = require("../src/secrets");

const INPUT_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const CHUNK_MS = 100;
const CHUNK_BYTES = INPUT_RATE * BYTES_PER_SAMPLE * CHUNK_MS / 1000;
const SILENCE_MS = 1500;

loadLocalEnv();

const apiKey = getGeminiApiKey();
const pcmPath = process.argv[2];

if (!apiKey) fail("missing_api_key: run Mimi Setup or set GEMINI_API_KEY as a developer fallback");
if (!pcmPath) fail("missing_pcm_path: pass a raw 16kHz mono s16le PCM file path");
if (!fs.existsSync(pcmPath)) fail(`pcm_not_found: ${pcmPath}`);

const input = Buffer.concat([
  fs.readFileSync(pcmPath),
  Buffer.alloc(INPUT_RATE * BYTES_PER_SAMPLE * SILENCE_MS / 1000),
]);

let setupComplete = false;
let sentBytes = 0;
let outputBytes = 0;
let inputTranscript = "";
let outputTranscript = "";
let lastError = "";
let sendTimer = null;

const session = new GeminiLiveTranslateSession({
  apiKey,
  model: process.env.JP_DUB_MODEL,
  endpoint: process.env.JP_DUB_GEMINI_ENDPOINT,
  targetLanguageCode: process.env.JP_DUB_TARGET_LANGUAGE || "ja",
  echoTargetLanguage: process.env.JP_DUB_ALLOW_TARGET_LANGUAGE_ECHO === "true",
  callbacks: {
    onStatus: (status) => {
      if (status === "translating") {
        setupComplete = true;
        startSending();
      }
    },
    onAudio: (audio) => {
      outputBytes += audio.length;
      maybePass();
    },
    onTranscript: (value) => {
      if (value.kind === "input") inputTranscript = value.text;
      if (value.kind === "output") outputTranscript = value.text;
      maybePass();
    },
    onError: (error, detail) => {
      lastError = detail || error;
      finish(false);
    },
  },
});

const timeout = setTimeout(() => finish(false), 25000);

try {
  session.start();
} catch (error) {
  fail(error.message || "gemini_start_failed");
}

function startSending() {
  if (sendTimer) return;
  sendTimer = setInterval(() => {
    if (sentBytes >= input.length) {
      clearInterval(sendTimer);
      sendTimer = null;
      return;
    }
    const next = input.subarray(sentBytes, Math.min(input.length, sentBytes + CHUNK_BYTES));
    sentBytes += next.length;
    session.sendAudio(next);
  }, CHUNK_MS);
}

function maybePass() {
  if (outputBytes > 0) finish(true);
}

function finish(ok) {
  clearTimeout(timeout);
  if (sendTimer) clearInterval(sendTimer);
  session.stop();
  const summary = {
    setupComplete,
    sentBytes,
    outputBytes,
    inputTranscript: inputTranscript.slice(0, 120),
    outputTranscript: outputTranscript.slice(0, 120),
    error: lastError.slice(0, 300),
    file: path.basename(pcmPath),
  };
  console.log(`${ok ? "PASS" : "FAIL"} stream ${JSON.stringify(summary)}`);
  process.exit(ok ? 0 : 1);
}

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}
