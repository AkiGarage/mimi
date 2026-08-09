#!/usr/bin/env node

const { loadLocalEnv } = require("../../local-server/src/localEnv");
const { readMessage, writeMessage } = require("../src/nativeProtocol");
const { ensureServer, status, stopServer } = require("../src/serverControl");

loadLocalEnv();

main().catch((error) => {
  writeMessage(process.stdout, { ok: false, error: safeError(error) });
});

async function main() {
  const message = await readMessage(process.stdin);
  const result = await handleMessage(message || {});
  writeMessage(process.stdout, { ok: true, ...result });
}

async function handleMessage(message) {
  if (message.type === "ping") {
    return { type: "pong", host: "com.akigarage.jp_dub" };
  }
  if (message.type === "status") {
    return { type: "status", status: await status() };
  }
  if (message.type === "ensure_server") {
    return { type: "ensure_server", ...(await ensureServer(message)) };
  }
  if (message.type === "stop_server") {
    return { type: "stop_server", ...(await stopServer()) };
  }
  throw new Error("unknown_native_host_message");
}

function safeError(error) {
  return String(error?.message || error || "native_host_error").slice(0, 300);
}
