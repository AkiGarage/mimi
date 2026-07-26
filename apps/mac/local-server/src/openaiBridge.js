const WebSocket = require("ws");

const DEFAULT_ENDPOINT = "wss://api.openai.com/v1/realtime/translations";
const DEFAULT_MODEL = "gpt-realtime-translate";
const INPUT_SAMPLE_RATE = 16000;
const API_SAMPLE_RATE = 24000;

class OpenAIRealtimeTranslateSession {
  constructor(options = {}) {
    this.apiKey = options.apiKey || "";
    this.endpoint = options.endpoint || DEFAULT_ENDPOINT;
    this.model = options.model || DEFAULT_MODEL;
    this.targetLanguageCode = options.targetLanguageCode || "ja";
    this.callbacks = options.callbacks || {};
    this.WebSocketImpl = options.WebSocketImpl || WebSocket;
    this.socket = null;
    this.ready = false;
    this.pendingAudio = [];
    this.maxPendingChunks = Number(options.maxPendingChunks || 6);
    this.generation = 0;
    this.failureReported = false;
  }

  start() {
    if (!this.apiKey) throw new Error("missing_openai_api_key");
    const generation = ++this.generation;
    this.failureReported = false;
    const url = new URL(this.endpoint);
    url.searchParams.set("model", this.model);
    const socket = new this.WebSocketImpl(url.toString(), {
      headers: { Authorization: `Bearer ${this.apiKey}` },
    });
    this.socket = socket;
    socket.on("open", () => {
      if (!this.isCurrent(socket, generation)) return;
      try {
        this.sendJson({
          type: "session.update",
          session: {
            audio: {
              output: {
                language: this.targetLanguageCode,
              },
            },
          },
        });
      } catch (error) {
        this.reportError("openai_send_failed", safeErrorDetail(error));
        return;
      }
      this.callbacks.onStatus?.("connecting");
    });
    socket.on("message", (data) => {
      if (this.isCurrent(socket, generation)) this.handleMessage(data);
    });
    socket.on("unexpected-response", (_request, response) => {
      if (!this.isCurrent(socket, generation)) {
        response.resume?.();
        return;
      }
      collectUnexpectedResponse(response, (statusCode, body) => {
        if (!this.isCurrent(socket, generation)) return;
        this.reportError(normalizeHttpErrorCode(statusCode), safeErrorDetail(`${statusCode}:${body}`));
      });
    });
    socket.on("error", (error) => {
      if (this.isCurrent(socket, generation)) {
        this.reportError("openai_network_error", safeErrorDetail(error));
      }
    });
    socket.on("close", (code, reason) => {
      if (!this.isCurrent(socket, generation)) return;
      this.ready = false;
      if (code !== 1000) {
        this.reportError("openai_connection_closed", safeCloseDetail(code, reason));
      }
    });
  }

  sendAudio(audio16k) {
    if (!Buffer.isBuffer(audio16k) || audio16k.length === 0) return false;
    if (!this.ready) {
      if (this.pendingAudio.length >= this.maxPendingChunks) this.pendingAudio.shift();
      this.pendingAudio.push(Buffer.from(audio16k));
      return false;
    }
    return this.sendAudioNow(audio16k);
  }

  sendAudioStreamEnd() {
    return true;
  }

  stop() {
    this.generation += 1;
    this.ready = false;
    this.pendingAudio = [];
    const socket = this.socket;
    this.socket = null;
    if (!socket) return;
    try {
      socket.removeAllListeners?.();
      socket.close(1000, "session_stopped");
    } catch {
      // The local session is already stopped even if the peer disappeared.
    }
  }

  handleMessage(data) {
    let event;
    try {
      event = JSON.parse(Buffer.isBuffer(data) ? data.toString("utf8") : String(data));
    } catch {
      this.callbacks.onError?.("openai_invalid_message", "");
      return;
    }
    if (event.type === "session.updated" || event.type === "session.created") {
      if (event.type === "session.updated") {
        this.ready = true;
        this.callbacks.onStatus?.("translating");
        const queued = this.pendingAudio;
        this.pendingAudio = [];
        for (const chunk of queued) {
          if (!this.sendAudioNow(chunk)) break;
        }
      }
      return;
    }
    if (event.type === "session.output_audio.delta" && event.delta) {
      this.callbacks.onAudio?.(Buffer.from(event.delta, "base64"));
      return;
    }
    if (event.type === "session.output_transcript.delta" && event.delta) {
      this.callbacks.onTranscript?.({ kind: "output", text: String(event.delta), isFinal: false });
      return;
    }
    if (event.type === "session.output_transcript.done") {
      this.callbacks.onTranscript?.({ kind: "output", text: String(event.transcript || ""), isFinal: true });
      return;
    }
    if (event.type === "error") {
      const code = normalizeErrorCode(event.error);
      this.callbacks.onError?.(code, safeErrorDetail(event.error));
    }
  }

  sendAudioNow(audio16k) {
    if (!this.ready || !isSocketOpen(this.socket, this.WebSocketImpl)) return false;
    if (!this.callbacks.shouldSendAudio?.(audio16k)) return false;
    const audio24k = resamplePcm16le(audio16k, INPUT_SAMPLE_RATE, API_SAMPLE_RATE);
    try {
      this.sendJson({
        type: "session.input_audio_buffer.append",
        audio: audio24k.toString("base64"),
      });
      this.callbacks.onInputAudioSent?.(audio16k.length);
      return true;
    } catch (error) {
      this.callbacks.onError?.("openai_send_failed", safeErrorDetail(error));
      return false;
    }
  }

  sendJson(value) {
    if (!isSocketOpen(this.socket, this.WebSocketImpl)) throw new Error("openai_socket_not_open");
    this.socket.send(JSON.stringify(value));
  }

  isCurrent(socket, generation) {
    return this.socket === socket && this.generation === generation;
  }

  reportError(code, detail) {
    if (this.failureReported) return;
    this.failureReported = true;
    this.callbacks.onError?.(code, detail);
  }
}

function isSocketOpen(socket, WebSocketImpl) {
  if (!socket) return false;
  const open = WebSocketImpl.OPEN ?? WebSocket.OPEN;
  return socket.readyState === open;
}

function resamplePcm16le(input, inputRate = INPUT_SAMPLE_RATE, outputRate = API_SAMPLE_RATE) {
  if (!Buffer.isBuffer(input) || input.length < 2) return Buffer.alloc(0);
  const inputSamples = Math.floor(input.length / 2);
  const outputSamples = Math.floor(inputSamples * outputRate / inputRate);
  const output = Buffer.alloc(outputSamples * 2);
  for (let index = 0; index < outputSamples; index += 1) {
    const source = index * inputRate / outputRate;
    const lowerIndex = Math.floor(source);
    const upperIndex = Math.min(inputSamples - 1, lowerIndex + 1);
    const fraction = source - lowerIndex;
    const lower = input.readInt16LE(lowerIndex * 2);
    const upper = input.readInt16LE(upperIndex * 2);
    const sample = Math.max(-32768, Math.min(32767, Math.round(lower + (upper - lower) * fraction)));
    output.writeInt16LE(sample, index * 2);
  }
  return output;
}

function normalizeErrorCode(error) {
  const code = typeof error === "string"
    ? error
    : String(error?.code || error?.type || error?.message || error || "");
  if (/auth|api_key|unauthorized/i.test(code)) return "openai_auth_error";
  if (/rate_limit|quota/i.test(code)) return "openai_rate_limit";
  return "openai_api_error";
}

function normalizeHttpErrorCode(statusCode) {
  if (statusCode === 401 || statusCode === 403) return "openai_auth_error";
  if (statusCode === 404) return "openai_not_found";
  if (statusCode === 429) return "openai_rate_limit";
  return "openai_api_error";
}

function collectUnexpectedResponse(response, callback) {
  const statusCode = Number(response?.statusCode || 0);
  let body = "";
  response.setEncoding?.("utf8");
  response.on?.("data", (chunk) => {
    body = `${body}${chunk}`.slice(0, 500);
  });
  response.on?.("end", () => callback(statusCode, body));
  response.resume?.();
}

function safeErrorDetail(error) {
  const text = String(error?.message || error?.code || error || "");
  return text
    .replace(/Bearer\s+\S+/gi, "Bearer [REDACTED]")
    .replace(/\bsk-[A-Za-z0-9_-]+\b/g, "[REDACTED]")
    .slice(0, 500);
}

function safeCloseDetail(code, reason) {
  const reasonText = Buffer.isBuffer(reason) ? reason.toString("utf8") : String(reason || "");
  return safeErrorDetail(`${code}:${reasonText}`);
}

module.exports = {
  API_SAMPLE_RATE,
  DEFAULT_ENDPOINT,
  DEFAULT_MODEL,
  INPUT_SAMPLE_RATE,
  OpenAIRealtimeTranslateSession,
  resamplePcm16le,
};
