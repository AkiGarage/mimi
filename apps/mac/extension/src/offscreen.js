const INPUT_SAMPLE_RATE = 16000;
const OUTPUT_SAMPLE_RATE = 24000;
const INPUT_CHUNK_MS = 100;
const CHUNK_SAMPLES = INPUT_SAMPLE_RATE * INPUT_CHUNK_MS / 1000;
const CAPTURE_WORKLET_URL = "capture-worklet.js";
const MAX_PENDING_INPUT_CHUNKS = 6;
const OUTPUT_START_DELAY_SECONDS = 0.02;
const PROGRESS_PUBLISH_INTERVAL_MS = 250;
const SESSION_MODE = "real";

let socket = null;
let audioContext = null;
let mediaStream = null;
let sourceNode = null;
let processorNode = null;
let originalGain = null;
let japaneseGain = null;
let inputFloatQueue = [];
let inputQueuedSamples = 0;
let inputResampler = null;
let outputPlayhead = 0;
let outputSources = new Set();
let inputBytes = 0;
let outputBytes = 0;
let lastProgressPublishedAt = 0;
let stopping = false;
let socketError = "";
let audioStreamingEnabled = false;
let autoStopTimer = null;
let autoStopAtMs = 0;

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.target !== "offscreen") return false;
  handleMessage(message).then(sendResponse).catch((error) => {
    publish({ status: "error", error: error.message });
    sendResponse({ ok: false, error: error.message });
  });
  return true;
});

async function handleMessage(message) {
  if (message.type === "start") await startSession(message);
  if (message.type === "stop") await stopSession(message.reason || "user_stopped");
  if (message.type === "set_volumes") setVolumes(message);
  return { ok: true };
}

async function startSession(message) {
  await stopSession("restart");
  inputBytes = 0;
  outputBytes = 0;
  socketError = "";
  audioStreamingEnabled = false;
  autoStopAtMs = Date.now() + normalizeAutoStopSeconds(message.autoStopSeconds) * 1000;
  publish({ status: "capturing", mode: SESSION_MODE, error: "none", inputBytes, outputBytes, autoStopAtMs });
  await ensureAudioContext();
  await captureTab(message.streamId);
  setVolumes(message);
  connectSocket(message.serverUrl, message.targetLanguageCode || "ja", message.provider || "gemini");
  scheduleAutoStop();
}

async function ensureAudioContext() {
  audioContext = new AudioContext();
  await audioContext.audioWorklet.addModule(CAPTURE_WORKLET_URL);
  originalGain = audioContext.createGain();
  japaneseGain = audioContext.createGain();
  originalGain.connect(audioContext.destination);
  japaneseGain.connect(audioContext.destination);
  if (audioContext.state === "suspended") await audioContext.resume();
}

async function captureTab(streamId) {
  mediaStream = await navigator.mediaDevices.getUserMedia({
    audio: {
      mandatory: {
        chromeMediaSource: "tab",
        chromeMediaSourceId: streamId,
      },
    },
    video: false,
  });
  sourceNode = audioContext.createMediaStreamSource(mediaStream);
  processorNode = new AudioWorkletNode(audioContext, "jp-dub-capture", {
    numberOfInputs: 1,
    numberOfOutputs: 1,
    outputChannelCount: [1],
  });
  processorNode.port.onmessage = handleCaptureWorkletMessage;
  sourceNode.connect(originalGain);
  sourceNode.connect(processorNode);
  processorNode.connect(audioContext.destination);
}

function connectSocket(serverUrl, targetLanguageCode, provider) {
  const normalizedProvider = normalizeProvider(provider);
  if (!normalizedProvider) throw new Error("unsupported_provider");
  const nextSocket = new WebSocket(serverUrl);
  socket = nextSocket;
  nextSocket.binaryType = "arraybuffer";
  nextSocket.addEventListener("open", () => {
    nextSocket.send(JSON.stringify({ type: "start", mode: SESSION_MODE, targetLanguageCode, provider: normalizedProvider }));
    publish({ status: "connecting", mode: SESSION_MODE });
  });
  nextSocket.addEventListener("message", (event) => {
    handleSocketMessage(event.data).catch((error) => {
      publish({ status: "error", error: error.message });
    });
  });
  nextSocket.addEventListener("close", async () => {
    try {
      await handleSocketClose(nextSocket);
    } catch (error) {
      publish({ status: "error", error: error.message || socketError || "socket_closed" });
    }
  });
  nextSocket.addEventListener("error", () => {
    socketError = "local_server_unavailable_or_origin_rejected";
    publish({ status: "error", error: "local_server_unavailable" });
  });
}

function handleCaptureWorkletMessage(event) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  const payload = event.data;
  if (payload?.type !== "samples" || !(payload.samples instanceof Float32Array)) return;
  const resampled = resampleInput(payload.samples, payload.sampleRate || audioContext.sampleRate);
  enqueueInput(resampled);
  sendReadyChunks();
}

function resampleInput(input, fromRate) {
  if (fromRate === INPUT_SAMPLE_RATE) return input;
  if (!inputResampler || inputResampler.fromRate !== fromRate) {
    inputResampler = createStreamingResampler(fromRate, INPUT_SAMPLE_RATE);
  }
  return inputResampler.process(input);
}

function createStreamingResampler(fromRate, toRate) {
  const step = fromRate / toRate;
  return {
    fromRate,
    toRate,
    position: 0,
    tail: new Float32Array(0),
    process(input) {
      if (input.length === 0) return input;
      const samples = concatSamples(this.tail, input);
      const capacity = Math.ceil(samples.length / step) + 2;
      const output = new Float32Array(capacity);
      let outputLength = 0;
      while (this.position < samples.length - 1) {
        const left = Math.floor(this.position);
        const weight = this.position - left;
        output[outputLength] = samples[left] * (1 - weight) + samples[left + 1] * weight;
        outputLength += 1;
        this.position += step;
      }
      const consumed = Math.max(0, Math.min(samples.length - 1, Math.floor(this.position)));
      this.tail = samples.slice(consumed);
      this.position -= consumed;
      return output.slice(0, outputLength);
    },
  };
}

function concatSamples(left, right) {
  if (!left.length) return right;
  const output = new Float32Array(left.length + right.length);
  output.set(left, 0);
  output.set(right, left.length);
  return output;
}

function enqueueInput(samples) {
  inputFloatQueue.push(samples);
  inputQueuedSamples += samples.length;
}

function sendReadyChunks() {
  if (!audioStreamingEnabled) {
    trimQueuedSamples(CHUNK_SAMPLES * MAX_PENDING_INPUT_CHUNKS);
    return;
  }
  while (inputQueuedSamples >= CHUNK_SAMPLES) {
    const chunk = takeSamples(CHUNK_SAMPLES);
    sendAudioChunk(chunk);
  }
}

function sendAudioChunk(chunk) {
  const pcm = floatToInt16Pcm(chunk);
  inputBytes += pcm.byteLength;
  socket.send(pcm);
  publishProgress({ inputBytes });
}

function takeSamples(count) {
  const output = new Float32Array(count);
  let offset = 0;
  while (offset < count) {
    const head = inputFloatQueue[0];
    const take = Math.min(head.length, count - offset);
    output.set(head.subarray(0, take), offset);
    offset += take;
    if (take === head.length) {
      inputFloatQueue.shift();
    } else {
      inputFloatQueue[0] = head.subarray(take);
    }
    inputQueuedSamples -= take;
  }
  return output;
}

function trimQueuedSamples(maxSamples) {
  while (inputQueuedSamples > maxSamples && inputFloatQueue.length > 0) {
    const drop = inputQueuedSamples - maxSamples;
    const head = inputFloatQueue[0];
    if (head.length <= drop) {
      inputFloatQueue.shift();
      inputQueuedSamples -= head.length;
    } else {
      inputFloatQueue[0] = head.subarray(drop);
      inputQueuedSamples -= drop;
    }
  }
}

function floatToInt16Pcm(samples) {
  const buffer = new ArrayBuffer(samples.length * 2);
  const view = new DataView(buffer);
  for (let index = 0; index < samples.length; index += 1) {
    const sample = Math.max(-1, Math.min(1, samples[index]));
    view.setInt16(index * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
  }
  return buffer;
}

async function handleSocketClose(closedSocket) {
  if (closedSocket !== socket) return;
  if (!stopping && mediaStream) {
    await cleanupSession();
    publish({ status: "error", error: socketError || "socket_closed" });
  }
}

async function handleSocketMessage(data) {
  if (data instanceof ArrayBuffer) {
    playPcm(data);
    return;
  }
  const message = JSON.parse(data);
  if (message.type === "status") {
    await handleStatusMessage(message);
    return;
  }
  if (message.type === "audio_format") outputPlayhead = Math.max(outputPlayhead, audioContext.currentTime);
  if (message.type === "billing") {
    publish({ billing: message.billing, openaiBudget: message.openaiBudget });
  }
  if (message.type === "transcript") publish({ transcript: message.text, transcriptKind: message.kind });
  if (message.type === "error") {
    closeSocketBeforeCleanup();
    await cleanupSession();
    publish({
      status: "error",
      error: message.error,
      billing: message.billing,
      openaiBudget: message.openaiBudget,
      latestDiagnostic: message.detail ? {
        timestamp: new Date().toISOString(),
        stage: message.provider || "translation",
        code: message.error,
        detail: message.detail,
      } : undefined,
    });
  }
}

async function handleStatusMessage(message) {
  audioStreamingEnabled = message.status === "translating";
  if (audioStreamingEnabled) sendReadyChunks();
  if (message.status === "idle" && isTerminalServerReason(message.reason)) {
    closeSocketBeforeCleanup();
    await cleanupSession();
  }
  publish(messageToPatch(message));
}

function playPcm(arrayBuffer) {
  if (!audioContext || !japaneseGain) return;
  const samples = new Int16Array(arrayBuffer);
  const buffer = audioContext.createBuffer(1, samples.length, OUTPUT_SAMPLE_RATE);
  const channel = buffer.getChannelData(0);
  for (let index = 0; index < samples.length; index += 1) channel[index] = samples[index] / 32768;
  const source = audioContext.createBufferSource();
  source.buffer = buffer;
  source.connect(japaneseGain);
  outputSources.add(source);
  source.addEventListener("ended", () => outputSources.delete(source), { once: true });
  outputPlayhead = Math.max(outputPlayhead, audioContext.currentTime + OUTPUT_START_DELAY_SECONDS);
  source.start(outputPlayhead);
  outputPlayhead += buffer.duration;
  outputBytes += arrayBuffer.byteLength;
  publishProgress({ outputBytes });
}

function messageToPatch(message) {
  return {
    status: message.status,
    mode: message.mode || SESSION_MODE,
    targetLanguageCode: message.targetLanguageCode,
    provider: normalizeProvider(message.provider),
    billing: message.billing,
    openaiBudget: message.openaiBudget,
    error: message.error || "none",
    lastStopReason: message.reason || "",
    autoStopAtMs: audioStreamingEnabled ? autoStopAtMs : 0,
  };
}

function normalizeProvider(value) {
  if (value === undefined || value === null || String(value).trim() === "") return "gemini";
  const provider = String(value).trim().toLowerCase();
  if (provider === "xai" || provider === "grok") return "gemini";
  return provider === "gemini" || provider === "openai" ? provider : "";
}

function setVolumes(message) {
  if (originalGain) originalGain.gain.value = clampVolume(message.originalVolume, 0.35);
  if (japaneseGain) japaneseGain.gain.value = clampVolume(message.translatedVolume ?? message.japaneseVolume, 0.85);
}

async function stopSession(reason) {
  stopping = true;
  clearAutoStop();
  try {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: "stop", reason }));
      socket.close();
    }
    await cleanupSession();
    publish({ status: "idle", error: reason === "auto_stop_timer" ? "auto_stop_timer" : "none", lastStopReason: reason, autoStopAtMs: 0 });
  } finally {
    stopping = false;
  }
}

function closeSocketBeforeCleanup() {
  if (socket && socket.readyState === WebSocket.OPEN) socket.close();
}

async function cleanupSession() {
  clearAutoStop();
  socket = null;
  if (processorNode) {
    processorNode.port.onmessage = null;
    processorNode.port.close();
    processorNode.disconnect();
  }
  if (sourceNode) sourceNode.disconnect();
  if (mediaStream) mediaStream.getTracks().forEach((track) => track.stop());
  resetOutputQueue();
  const closingContext = audioContext;
  audioContext = null;
  mediaStream = null;
  sourceNode = null;
  processorNode = null;
  inputFloatQueue = [];
  inputQueuedSamples = 0;
  inputResampler = null;
  audioStreamingEnabled = false;
  outputPlayhead = 0;
  lastProgressPublishedAt = 0;
  if (closingContext) await closingContext.close().catch(() => null);
}

function scheduleAutoStop() {
  clearAutoStop();
  const delay = Math.max(1000, autoStopAtMs - Date.now());
  autoStopTimer = setTimeout(() => {
    stopSession("auto_stop_timer").catch((error) => {
      publish({ status: "error", error: error.message });
    });
  }, delay);
}

function clearAutoStop() {
  if (!autoStopTimer) return;
  clearTimeout(autoStopTimer);
  autoStopTimer = null;
}

function normalizeAutoStopSeconds(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return 30 * 60;
  return Math.min(120 * 60, Math.max(60, Math.round(seconds)));
}

function isTerminalServerReason(reason) {
  return reason === "monthly_limit_reached" || reason === "auto_stop_timer";
}

function resetOutputQueue() {
  for (const source of outputSources) {
    try {
      source.stop();
    } catch {
      // The source may have already ended; it is safe to ignore.
    }
  }
  outputSources.clear();
}

function publishProgress(patch) {
  const now = Date.now();
  if (now - lastProgressPublishedAt < PROGRESS_PUBLISH_INTERVAL_MS) return;
  lastProgressPublishedAt = now;
  publish(patch);
}

function publish(patch) {
  chrome.runtime.sendMessage({ target: "service-worker", type: "status_event", patch }).catch(() => {});
}

function clampVolume(value, fallback) {
  if (!Number.isFinite(value)) return fallback;
  return Math.min(1, Math.max(0, value));
}
