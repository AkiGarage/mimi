const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

test("playPcm schedules translated audio immediately with native 24kHz buffers", async () => {
  const harness = loadOffscreenHarness();
  await harness.context.ensureAudioContext();

  harness.audioContext.currentTime = 10;
  harness.context.playPcm(makeConstantPcmBuffer(2400, 16000));

  assert.equal(harness.audioContext.buffers[0].sampleRate, 24000);
  assert.equal(harness.audioContext.buffers[0].length, 2400);
  assert.equal(harness.audioContext.buffers[0].getChannelData(0)[96], 16000 / 32768);
  assert.deepEqual(harness.audioContext.starts, [10.02]);
});

test("playPcm does not reshape translated PCM at burst starts", async () => {
  const harness = loadOffscreenHarness();
  await harness.context.ensureAudioContext();

  harness.audioContext.currentTime = 10;
  harness.context.playPcm(makeConstantPcmBuffer(2400, 16000));
  harness.context.playPcm(makeConstantPcmBuffer(2400, 12000));

  assert.equal(harness.audioContext.buffers.length, 2);
  assert.equal(harness.audioContext.buffers[0].getChannelData(0)[0], 16000 / 32768);
  assert.equal(harness.audioContext.buffers[1].getChannelData(0)[0], 12000 / 32768);
  assert.deepEqual(harness.audioContext.starts, [10.02, 10.12]);
});

test("playPcm keeps direct PCM values after a playback gap", async () => {
  const harness = loadOffscreenHarness();
  await harness.context.ensureAudioContext();

  harness.audioContext.currentTime = 10;
  harness.context.playPcm(makeConstantPcmBuffer(2400, 16000));
  harness.audioContext.currentTime = 11;
  harness.context.playPcm(makeConstantPcmBuffer(2400, 12000));

  assert.equal(harness.audioContext.buffers.length, 2);
  assert.equal(harness.audioContext.buffers[1].getChannelData(0)[0], 12000 / 32768);
  assert.deepEqual(harness.audioContext.starts, [10.02, 11.02]);
});

test("playPcm does not force-stop queued translated audio", async () => {
  const harness = loadOffscreenHarness();
  await harness.context.ensureAudioContext();

  for (let index = 0; index < 30; index += 1) {
    harness.context.playPcm(makePcmBuffer(24000));
  }

  assert.equal(harness.audioContext.stops, 0);
});

test("silent input is still sent as continuous PCM instead of ending the stream", () => {
  const harness = loadOffscreenHarness();
  const socket = {
    readyState: harness.context.WebSocket.OPEN,
    sent: [],
    send(value) {
      this.sent.push(value);
    },
  };
  harness.context.__offscreenTest.setSocket(socket);
  harness.context.__offscreenTest.setAudioStreamingEnabled(true);

  harness.context.enqueueInput(new Float32Array(1600));
  harness.context.sendReadyChunks();

  assert.equal(socket.sent.length, 1);
  assert.equal(socket.sent[0].byteLength, 3200);
  assert.equal(socket.sent.some((value) => String(value).includes("audio_stream_end")), false);
});

test("streaming resampler preserves fractional source samples across worklet blocks", () => {
  const harness = loadOffscreenHarness();
  const resampler = harness.context.createStreamingResampler(48000, 16000);
  const first = resampler.process(new Float32Array(1024));
  const second = resampler.process(new Float32Array(1024));
  const third = resampler.process(new Float32Array(1024));

  assert.equal(first.length + second.length + third.length, 1024);
});

test("offscreen websocket start always requests real mode", () => {
  const harness = loadOffscreenHarness();
  harness.context.connectSocket("ws://127.0.0.1:8787/ws", "ja");
  harness.webSocket.dispatch("open");

  assert.deepEqual(JSON.parse(harness.webSocket.sent[0]), {
    type: "start",
    mode: "real",
    targetLanguageCode: "ja",
    provider: "gemini",
  });
});

test("offscreen forwards the selected paid provider without any API key", () => {
  const harness = loadOffscreenHarness();
  harness.context.connectSocket("ws://127.0.0.1:8787/ws", "ja", "openai");
  harness.webSocket.dispatch("open");
  const message = JSON.parse(harness.webSocket.sent[0]);
  assert.equal(message.provider, "openai");
  assert.equal(Object.prototype.hasOwnProperty.call(message, "apiKey"), false);
});

test("offscreen migrates a stale xAI websocket provider to Gemini", () => {
  const harness = loadOffscreenHarness();
  harness.context.connectSocket("ws://127.0.0.1:8787/ws", "ja", "xai");
  harness.webSocket.dispatch("open");
  const message = JSON.parse(harness.webSocket.sent[0]);
  assert.equal(message.provider, "gemini");
  assert.equal(Object.prototype.hasOwnProperty.call(message, "apiKey"), false);
});

test("offscreen closes websocket when the server reports a terminal idle reason", () => {
  const harness = loadOffscreenHarness();
  harness.context.connectSocket("ws://127.0.0.1:8787/ws", "ja");
  const socket = harness.webSocket;

  harness.context.handleSocketMessage(JSON.stringify({
    type: "status",
    status: "idle",
    reason: "monthly_limit_reached",
  }));

  assert.equal(socket.closed, true);
  socket.dispatch("close");
});

test("offscreen cleans up capture resources when the server reports an error", async () => {
  const harness = loadOffscreenHarness();
  await harness.context.ensureAudioContext();
  const audioContext = harness.audioContext;
  const track = { stop: () => harness.events.push("track:stop") };

  harness.context.connectSocket("ws://127.0.0.1:8787/ws", "ja");
  const socket = harness.webSocket;
  harness.context.__offscreenTest.setMediaStream({ getTracks: () => [track] });

  await harness.context.handleSocketMessage(JSON.stringify({
    type: "error",
    error: "gemini_project_access_denied",
    detail: "safe detail",
  }));

  assert.equal(socket.closed, true);
  assert.equal(audioContext.closed, true);
  assert.deepEqual(harness.events, ["socket:close", "track:stop", "audioContext:close", "publish:error"]);
  assert.equal(harness.published.at(-1).patch.error, "gemini_project_access_denied");
});

test("offscreen awaits cleanup before publishing an unexpected socket close error", async () => {
  const harness = loadOffscreenHarness({ delayAudioClose: true });
  await harness.context.ensureAudioContext();
  const track = { stop: () => harness.events.push("track:stop") };

  harness.context.connectSocket("ws://127.0.0.1:8787/ws", "ja");
  harness.context.__offscreenTest.setMediaStream({ getTracks: () => [track] });

  const close = harness.webSocket.dispatch("close");
  await Promise.resolve();

  assert.equal(harness.events.join("|"), "track:stop|audioContext:close-start");

  harness.resolveAudioClose();
  await close;

  assert.equal(harness.events.join("|"), "track:stop|audioContext:close-start|audioContext:close|publish:error");
  assert.equal(harness.published.at(-1).patch.error, "socket_closed");
});

function loadOffscreenHarness(options = {}) {
  const filePath = path.resolve(__dirname, "..", "src", "offscreen.js");
  const source = fs.readFileSync(filePath, "utf8");
  const harness = { audioContext: null, events: [], published: [] };
  class MockAudioContext {
    constructor() {
      this.currentTime = 0;
      this.sampleRate = 48000;
      this.destination = {};
      this.state = "running";
      this.buffers = [];
      this.starts = [];
      this.stops = 0;
      this.audioWorklet = { addModule: async () => undefined };
      harness.audioContext = this;
    }

    createGain() {
      return { gain: { value: 1 }, connect: () => undefined, disconnect: () => undefined };
    }

    createBuffer(channels, length, sampleRate) {
      const channel = new Float32Array(length);
      const buffer = {
        channels,
        length,
        sampleRate,
        duration: length / sampleRate,
        getChannelData: () => channel,
      };
      this.buffers.push(buffer);
      return buffer;
    }

    createBufferSource() {
      return {
        buffer: null,
        connect: () => undefined,
        addEventListener: () => undefined,
        stop: () => {
          this.stops += 1;
        },
        start: (time) => this.starts.push(Number(time.toFixed(5))),
      };
    }

    resume() {
      return Promise.resolve();
    }

    close() {
      this.closed = true;
      if (!options.delayAudioClose) {
        harness.events.push("audioContext:close");
        return Promise.resolve();
      }
      harness.events.push("audioContext:close-start");
      return new Promise((resolve) => {
        harness.resolveAudioClose = () => {
          harness.events.push("audioContext:close");
          resolve();
        };
      });
    }
  }

  const context = {
    AudioContext: MockAudioContext,
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
    clearTimeout: (timer) => {
      timer.active = false;
    },
    setTimeout: (callback) => {
      const timer = { active: true, callback };
      harness.timers.push(timer);
      return timer;
    },
    WebSocket: class MockWebSocket {
      constructor(url) {
        this.url = url;
        this.binaryType = "";
        this.readyState = MockWebSocket.OPEN;
        this.listeners = {};
        this.sent = [];
        harness.webSocket = this;
      }

      addEventListener(type, listener) {
        this.listeners[type] = listener;
      }

      send(value) {
        this.sent.push(value);
      }

      close() {
        harness.events.push("socket:close");
        this.closed = true;
        this.readyState = MockWebSocket.CLOSED;
      }

      dispatch(type, data = {}) {
        return this.listeners[type]?.(data);
      }
    },
    chrome: {
      runtime: {
        onMessage: { addListener: () => undefined },
        sendMessage: (message) => {
          harness.events.push(`publish:${message?.patch?.status || message?.status || "patch"}`);
          harness.published.push(message);
          return { catch: () => undefined };
        },
      },
    },
    navigator: { mediaDevices: { getUserMedia: async () => ({ getTracks: () => [] }) } },
  };
  context.WebSocket.OPEN = 1;
  context.WebSocket.CLOSED = 3;
  harness.timers = [];
  harness.runTimers = () => {
    const timers = harness.timers.splice(0);
    for (const timer of timers) {
      if (timer.active) timer.callback();
    }
  };
  vm.runInNewContext(`${source}
globalThis.__offscreenTest = {
  setSocket(value) { socket = value; },
  setAudioStreamingEnabled(value) { audioStreamingEnabled = value; },
  setMediaStream(value) { mediaStream = value; },
};
`, context);
  harness.context = context;
  return harness;
}

function makePcmBuffer(sampleCount) {
  const buffer = new ArrayBuffer(sampleCount * 2);
  const view = new DataView(buffer);
  for (let index = 0; index < sampleCount; index += 1) view.setInt16(index * 2, index % 32767, true);
  return buffer;
}

function makeConstantPcmBuffer(sampleCount, value) {
  const buffer = new ArrayBuffer(sampleCount * 2);
  const view = new DataView(buffer);
  for (let index = 0; index < sampleCount; index += 1) view.setInt16(index * 2, value, true);
  return buffer;
}
