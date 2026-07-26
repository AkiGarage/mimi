const crypto = require("crypto");

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function acceptKey(key) {
  return crypto.createHash("sha1").update(key + GUID).digest("base64");
}

function sendFrame(socket, opcode, payload) {
  if (socket.destroyed || !socket.writable) return;
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const header = makeHeader(opcode, body.length);
  socket.write(Buffer.concat([header, body]));
}

function makeHeader(opcode, length) {
  if (length < 126) {
    return Buffer.from([0x80 | opcode, length]);
  }
  if (length <= 0xffff) {
    const header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
    return header;
  }
  const header = Buffer.alloc(10);
  header[0] = 0x80 | opcode;
  header[1] = 127;
  header.writeBigUInt64BE(BigInt(length), 2);
  return header;
}

function parseFrames(state, chunk, onFrame) {
  state.buffer = Buffer.concat([state.buffer, chunk]);
  while (state.buffer.length >= 2) {
    const parsed = parseOneFrame(state.buffer);
    if (!parsed) return;
    state.buffer = state.buffer.subarray(parsed.nextOffset);
    onFrame(parsed.frame);
  }
}

function parseOneFrame(buffer) {
  const first = buffer[0];
  const second = buffer[1];
  let length = second & 0x7f;
  let offset = 2;

  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    length = Number(buffer.readBigUInt64BE(2));
    offset = 10;
  }

  const masked = Boolean(second & 0x80);
  const maskOffset = masked ? offset : -1;
  offset += masked ? 4 : 0;
  if (buffer.length < offset + length) return null;
  const payload = Buffer.from(buffer.subarray(offset, offset + length));
  if (masked) unmask(payload, buffer.subarray(maskOffset, maskOffset + 4));
  return { nextOffset: offset + length, frame: { opcode: first & 0x0f, payload } };
}

function unmask(payload, mask) {
  for (let index = 0; index < payload.length; index += 1) {
    payload[index] ^= mask[index % 4];
  }
}

function createPeer(socket) {
  const state = { buffer: Buffer.alloc(0), handlers: [], closeHandlers: [] };
  socket.on("data", (chunk) => parseFrames(state, chunk, (frame) => handleFrame(socket, state, frame)));
  socket.on("close", () => state.closeHandlers.forEach((handler) => handler()));
  socket.on("error", () => socket.destroy());
  return {
    sendText: (value) => sendFrame(socket, 0x1, JSON.stringify(value)),
    sendBinary: (value) => sendFrame(socket, 0x2, value),
    close: () => socket.end(),
    onMessage: (handler) => state.handlers.push(handler),
    onClose: (handler) => state.closeHandlers.push(handler),
  };
}

function handleFrame(socket, state, frame) {
  if (frame.opcode === 0x8) {
    socket.end();
    return;
  }
  if (frame.opcode === 0x9) {
    sendFrame(socket, 0xA, frame.payload);
    return;
  }
  state.handlers.forEach((handler) => handler(frame));
}

function attachWebSocketServer(server, options) {
  server.on("upgrade", (request, socket) => {
    const url = new URL(request.url || "/", "http://127.0.0.1");
    if (url.pathname !== options.path) {
      socket.end("HTTP/1.1 404 Not Found\r\n\r\n");
      return;
    }
    if (options.isAllowedOrigin && !options.isAllowedOrigin(request.headers.origin || "")) {
      socket.end("HTTP/1.1 403 Forbidden\r\n\r\n");
      return;
    }
    const key = request.headers["sec-websocket-key"];
    if (!key) {
      socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
      return;
    }
    socket.write(makeHandshakeResponse(key));
    options.onConnection(createPeer(socket), request);
  });
}

function makeHandshakeResponse(key) {
  return [
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${acceptKey(key)}`,
    "",
    "",
  ].join("\r\n");
}

module.exports = {
  attachWebSocketServer,
};
