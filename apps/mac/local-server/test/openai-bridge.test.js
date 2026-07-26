const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const test = require("node:test");
const {
  OpenAIRealtimeTranslateSession,
  resamplePcm16le,
} = require("../src/openaiBridge");

class FakeWebSocket extends EventEmitter {
  static OPEN = 1;

  constructor(url, options) {
    super();
    this.url = url;
    this.options = options;
    this.readyState = 0;
    this.sent = [];
    FakeWebSocket.instance = this;
  }

  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.emit("open");
  }

  send(value) {
    this.sent.push(JSON.parse(value));
  }

  close() {
    this.readyState = 3;
  }
}

test("OpenAI bridge keeps the key in the Authorization header and translates queued PCM", () => {
  const audio = Buffer.alloc(3200, 7);
  const output = [];
  const sentInput = [];
  const statuses = [];
  const session = new OpenAIRealtimeTranslateSession({
    apiKey: "test-secret-key",
    WebSocketImpl: FakeWebSocket,
    callbacks: {
      shouldSendAudio: () => true,
      onInputAudioSent: (bytes) => sentInput.push(bytes),
      onAudio: (value) => output.push(value),
      onStatus: (value) => statuses.push(value),
    },
  });

  session.start();
  const socket = FakeWebSocket.instance;
  assert.equal(socket.options.headers.Authorization, "Bearer test-secret-key");
  assert.doesNotMatch(socket.url, /test-secret-key/);
  assert.equal(session.sendAudio(audio), false);

  socket.open();
  assert.deepEqual(socket.sent[0], {
    type: "session.update",
    session: { audio: { output: { language: "ja" } } },
  });
  socket.emit("message", JSON.stringify({ type: "session.updated" }));

  assert.equal(socket.sent[1].type, "session.input_audio_buffer.append");
  assert.equal(Buffer.from(socket.sent[1].audio, "base64").length, 4800);
  assert.deepEqual(sentInput, [3200]);
  assert.deepEqual(statuses, ["connecting", "translating"]);

  const translated = Buffer.from([1, 2, 3, 4]);
  socket.emit("message", JSON.stringify({
    type: "session.output_audio.delta",
    delta: translated.toString("base64"),
  }));
  assert.deepEqual(output, [translated]);
});

test("OpenAI bridge does not send audio when the local budget rejects it", () => {
  const session = new OpenAIRealtimeTranslateSession({
    apiKey: "test-secret-key",
    WebSocketImpl: FakeWebSocket,
    callbacks: { shouldSendAudio: () => false },
  });
  session.start();
  const socket = FakeWebSocket.instance;
  socket.open();
  socket.emit("message", JSON.stringify({ type: "session.updated" }));
  assert.equal(session.sendAudio(Buffer.alloc(3200)), false);
  assert.equal(socket.sent.filter((event) => event.type === "session.input_audio_buffer.append").length, 0);
});

test("OpenAI bridge reserves budget only for startup chunks that are actually sent", () => {
  let reservations = 0;
  const session = new OpenAIRealtimeTranslateSession({
    apiKey: "test-secret-key",
    WebSocketImpl: FakeWebSocket,
    maxPendingChunks: 2,
    callbacks: {
      shouldSendAudio: () => {
        reservations += 1;
        return true;
      },
    },
  });
  session.start();
  const socket = FakeWebSocket.instance;
  session.sendAudio(Buffer.alloc(3200, 1));
  session.sendAudio(Buffer.alloc(3200, 2));
  session.sendAudio(Buffer.alloc(3200, 3));
  assert.equal(reservations, 0);

  socket.open();
  socket.emit("message", JSON.stringify({ type: "session.updated" }));
  assert.equal(reservations, 2);
  assert.equal(socket.sent.filter((event) => event.type === "session.input_audio_buffer.append").length, 2);
});

test("OpenAI bridge ignores delayed events from a stopped socket", () => {
  const errors = [];
  const audio = [];
  const session = new OpenAIRealtimeTranslateSession({
    apiKey: "test-secret-key",
    WebSocketImpl: FakeWebSocket,
    callbacks: {
      shouldSendAudio: () => true,
      onAudio: (value) => audio.push(value),
      onError: (code) => errors.push(code),
    },
  });
  session.start();
  const oldSocket = FakeWebSocket.instance;
  session.stop();
  session.start();
  const currentSocket = FakeWebSocket.instance;

  oldSocket.emit("message", JSON.stringify({
    type: "session.output_audio.delta",
    delta: Buffer.from([1]).toString("base64"),
  }));
  oldSocket.emit("close", 1006, "stale");
  assert.deepEqual(audio, []);
  assert.deepEqual(errors, []);

  currentSocket.open();
  currentSocket.emit("message", JSON.stringify({
    type: "error",
    error: { message: "invalid_api_key" },
  }));
  assert.deepEqual(errors, ["openai_auth_error"]);
});

test("OpenAI bridge reports a redacted HTTP handshake failure body", () => {
  const errors = [];
  const session = new OpenAIRealtimeTranslateSession({
    apiKey: "test-secret-key",
    WebSocketImpl: FakeWebSocket,
    callbacks: {
      onError: (code, detail) => errors.push({ code, detail }),
    },
  });
  session.start();
  const socket = FakeWebSocket.instance;
  const response = new EventEmitter();
  response.statusCode = 404;
  socket.emit("unexpected-response", {}, response);
  response.emit("data", Buffer.from('{"error":{"message":"model unavailable sk-secret-value"}}'));
  response.emit("end");

  assert.deepEqual(errors, [{
    code: "openai_not_found",
    detail: '404:{"error":{"message":"model unavailable [REDACTED]"}}',
  }]);
});

test("16 kHz PCM is resampled to 24 kHz PCM", () => {
  const input = Buffer.alloc(1600 * 2);
  for (let index = 0; index < 1600; index += 1) input.writeInt16LE(index - 800, index * 2);
  const output = resamplePcm16le(input);
  assert.equal(output.length, 2400 * 2);
  assert.equal(output.readInt16LE(0), -800);
});
