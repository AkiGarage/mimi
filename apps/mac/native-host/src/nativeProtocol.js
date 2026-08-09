function encodeMessage(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32LE(body.length, 0);
  return Buffer.concat([header, body]);
}

function decodeMessage(buffer) {
  if (buffer.length < 4) throw new Error("native_message_header_missing");
  const length = buffer.readUInt32LE(0);
  if (buffer.length < 4 + length) throw new Error("native_message_body_incomplete");
  return JSON.parse(buffer.subarray(4, 4 + length).toString("utf8"));
}

function readMessage(stream) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let expected = 0;
    let done = false;

    function cleanup() {
      stream.off("data", onData);
      stream.off("end", onEnd);
      stream.off("error", onError);
    }

    function finish(value) {
      if (done) return;
      done = true;
      cleanup();
      resolve(value);
    }

    function onData(chunk) {
      chunks.push(chunk);
      total += chunk.length;
      const buffer = Buffer.concat(chunks, total);
      if (!expected && buffer.length >= 4) expected = 4 + buffer.readUInt32LE(0);
      if (expected && buffer.length >= expected) finish(decodeMessage(buffer.subarray(0, expected)));
    }

    function onEnd() {
      if (!done) reject(new Error("native_message_stream_ended"));
    }

    function onError(error) {
      if (!done) reject(error);
    }

    stream.on("data", onData);
    stream.on("end", onEnd);
    stream.on("error", onError);
    stream.resume();
  });
}

function writeMessage(stream, message) {
  stream.write(encodeMessage(message));
}

module.exports = {
  decodeMessage,
  encodeMessage,
  readMessage,
  writeMessage,
};
