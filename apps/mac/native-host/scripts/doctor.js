const fs = require("fs");
const { spawnSync } = require("child_process");
const { decodeMessage, encodeMessage } = require("../src/nativeProtocol");
const { chromeManifestPath, HOST_NAME } = require("../src/hostManifest");

const manifestPath = chromeManifestPath();

main();

function main() {
  print("host", HOST_NAME);
  print("manifest", manifestPath);
  if (!fs.existsSync(manifestPath)) fail("native host manifest is not installed");

  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  print("manifest name", manifest.name);
  print("host path", manifest.path);
  print("allowed origins", (manifest.allowed_origins || []).join(", "));
  if (manifest.name !== HOST_NAME) fail("manifest name mismatch");
  if (!fs.existsSync(manifest.path)) fail("host executable missing");

  const probe = spawnSync(manifest.path, {
    input: encodeMessage({ type: "ping" }),
    encoding: "buffer",
    timeout: 5000,
  });
  if (probe.error) fail(probe.error.message);
  if (probe.status !== 0) fail(`host exited with status ${probe.status}`);
  const response = decodeMessage(probe.stdout);
  if (!response.ok || response.type !== "pong") fail(response.error || "unexpected host response");
  print("host ping", "ok");
}

function print(label, value) {
  console.log(`${label}: ${value}`);
}

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}
