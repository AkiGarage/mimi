const DEFAULT_MODEL = "gemini-3.5-live-translate-preview";
const DEFAULT_TARGET_LANGUAGE = "ja";
const DEFAULT_ENDPOINT = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";
const DEFAULT_MAX_PENDING_AUDIO_CHUNKS = 6;

class GeminiLiveTranslateSession {
  constructor(options = {}) {
    this.apiKey = options.apiKey;
    this.model = options.model || DEFAULT_MODEL;
    this.targetLanguageCode = options.targetLanguageCode || DEFAULT_TARGET_LANGUAGE;
    this.echoTargetLanguage = options.echoTargetLanguage === true;
    this.endpoint = options.endpoint || DEFAULT_ENDPOINT;
    this.callbacks = options.callbacks || {};
    this.maxPendingAudioChunks = positiveInteger(options.maxPendingAudioChunks, DEFAULT_MAX_PENDING_AUDIO_CHUNKS);
    this.socket = null;
    this.ready = false;
    this.pendingAudio = [];
    this.stopping = false;
  }

  start() {
    if (!this.apiKey) throw new Error("missing_api_key");
    if (typeof WebSocket === "undefined") throw new Error("node_websocket_unavailable");
    const url = `${this.endpoint}?key=${encodeURIComponent(this.apiKey)}`;
    this.socket = new WebSocket(url);
    this.socket.addEventListener("open", () => this.handleOpen());
    this.socket.addEventListener("message", (event) => this.handleMessage(event.data));
    this.socket.addEventListener("error", () => this.emitError("network_error"));
    this.socket.addEventListener("close", (event) => this.handleClose(event));
  }

  sendAudio(buffer) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return false;
    if (!this.ready) {
      this.queueAudio(buffer);
      return true;
    }
    return this.sendAudioNow(buffer);
  }

  queueAudio(buffer) {
    this.pendingAudio.push(Buffer.from(buffer));
    while (this.pendingAudio.length > this.maxPendingAudioChunks) this.pendingAudio.shift();
  }

  sendAudioNow(buffer) {
    const audio = Buffer.from(buffer);
    if (this.callbacks.shouldSendAudio?.(audio) === false) return false;
    const message = {
      realtimeInput: {
        audio: {
          data: audio.toString("base64"),
          mimeType: "audio/pcm;rate=16000",
        },
      },
    };
    this.socket.send(JSON.stringify(message));
    this.callbacks.onInputAudioSent?.(audio.length);
    return true;
  }

  sendAudioStreamEnd() {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN || !this.ready) return false;
    this.socket.send(JSON.stringify({ realtimeInput: { audioStreamEnd: true } }));
    return true;
  }

  stop() {
    this.ready = false;
    this.pendingAudio = [];
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    this.stopping = true;
    try {
      socket.close();
    } catch {
      this.stopping = false;
    }
  }

  handleOpen() {
    this.socket.send(JSON.stringify(makeSetupMessage({
      model: this.model,
      targetLanguageCode: this.targetLanguageCode,
      echoTargetLanguage: this.echoTargetLanguage,
    })));
    this.callbacks.onStatus?.("connecting");
  }

  async handleMessage(data) {
    const text = await websocketDataToString(data);
    const message = safeJsonParse(text);
    if (!message) return;
    if (message.error) {
      this.emitError(classifyGeminiError(message.error), safeErrorDetail(message.error));
      return;
    }
    if (message.setupComplete) this.handleSetupComplete();
    this.handleServerContent(message.serverContent);
    if (message.usageMetadata) this.callbacks.onUsage?.(message.usageMetadata);
  }

  handleSetupComplete() {
    this.ready = true;
    this.callbacks.onStatus?.("translating");
    while (this.pendingAudio.length > 0 && this.socket?.readyState === WebSocket.OPEN) {
      if (!this.sendAudioNow(this.pendingAudio.shift())) break;
    }
  }

  handleServerContent(content) {
    if (!content) return;
    emitTranscript(this.callbacks, "output", content.outputTranscription);
    const parts = content.modelTurn?.parts || [];
    for (const part of parts) {
      if (part.inlineData?.data) {
        this.callbacks.onAudio?.(Buffer.from(part.inlineData.data, "base64"));
      }
    }
  }

  handleClose(event) {
    this.ready = false;
    if (this.stopping) {
      this.stopping = false;
      this.callbacks.onClose?.(event);
      return;
    }
    if (event.code && event.code !== 1000) {
      const detail = `close_${event.code}:${event.reason || "no_reason"}`;
      this.emitError(classifyGeminiError(detail), safeErrorDetail(detail));
    }
    this.callbacks.onClose?.(event);
  }

  emitError(error, detail = "") {
    this.callbacks.onError?.(error, detail);
  }
}

function makeSetupMessage(options = {}) {
  return {
    setup: {
      model: `models/${options.model || DEFAULT_MODEL}`,
      generationConfig: {
        responseModalities: ["AUDIO"],
        translationConfig: {
          targetLanguageCode: options.targetLanguageCode || DEFAULT_TARGET_LANGUAGE,
          echoTargetLanguage: options.echoTargetLanguage === true,
        },
      },
      outputAudioTranscription: {},
    },
  };
}

function emitTranscript(callbacks, kind, transcript) {
  if (transcript?.text) {
    callbacks.onTranscript?.({ kind, text: transcript.text, languageCode: transcript.languageCode });
  }
}

async function websocketDataToString(data) {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  if (typeof data?.arrayBuffer === "function") {
    return Buffer.from(await data.arrayBuffer()).toString("utf8");
  }
  return String(data);
}

function safeJsonParse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function classifyGeminiError(error) {
  const text = typeof error === "string" ? error : JSON.stringify(error);
  const normalized = text.toLowerCase();
  if (
    normalized.includes("project has been denied access") ||
    normalized.includes("permission_denied") ||
    normalized.includes("access restricted") ||
    /\b403\b/.test(normalized)
  ) {
    return "gemini_project_access_denied";
  }
  if (normalized.includes("quota") || normalized.includes("billing") || normalized.includes("resource_exhausted")) {
    return "quota_or_free_tier_error";
  }
  if (
    normalized.includes("api key") ||
    normalized.includes("permission") ||
    normalized.includes("unauthenticated") ||
    normalized.includes("forbidden")
  ) {
    return "auth_error";
  }
  if (normalized.includes("invalid_argument") || normalized.includes("bad request")) return "invalid_request";
  return "network_error";
}

function safeErrorDetail(error) {
  const text = typeof error === "string" ? error : JSON.stringify(error);
  return text
    .replace(/https?:\/\/[^\s"')]+/gi, "REDACTED_URL")
    .replace(/key=([A-Za-z0-9_-]+)/g, "REDACTED_KEY_FIELD")
    .replace(/AIza[0-9A-Za-z_-]*/g, "REDACTED_KEY")
    .slice(0, 500);
}

function positiveInteger(value, fallback) {
  return Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback;
}

module.exports = {
  DEFAULT_ENDPOINT,
  DEFAULT_MAX_PENDING_AUDIO_CHUNKS,
  DEFAULT_MODEL,
  DEFAULT_TARGET_LANGUAGE,
  GeminiLiveTranslateSession,
  classifyGeminiError,
  makeSetupMessage,
  safeErrorDetail,
};
