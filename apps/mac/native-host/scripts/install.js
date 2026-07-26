const fs = require("fs");
const path = require("path");
const { loadLocalEnv } = require("../../local-server/src/localEnv");
const { buildHostManifest, chromeManifestPath, nativeHostWrapperPath, HOST_NAME } = require("../src/hostManifest");
const { resolveExtensionOriginDetails } = require("../../shared/extensionOrigin.cjs");

const root = path.resolve(__dirname, "..");
const hostScriptPath = path.join(root, "bin", "jp-dub-native-host.js");
const wrapperPath = nativeHostWrapperPath();
const manifestPath = chromeManifestPath();

if (require.main === module) {
  main();
}

function main() {
  loadLocalEnv();
  const resolvedOrigin = resolveInstallOrigin();
  const extensionOrigin = resolvedOrigin.origin;
  if (!extensionOrigin) {
    fail("missing_extension_origin: install the fixed Mimi extension or pass --extension-origin=chrome-extension://<id>/");
  }

  writeWrapper();
  const manifest = buildHostManifest({ hostPath: wrapperPath, extensionOrigin });
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

  console.log(`installed native host: ${HOST_NAME}`);
  console.log(`manifest: ${manifestPath}`);
  console.log(`wrapper: ${wrapperPath}`);
  console.log(`allowed origin: ${manifest.allowed_origins[0]}`);
  console.log(`origin source: ${resolvedOrigin.source}`);
}

function writeWrapper() {
  fs.mkdirSync(path.dirname(wrapperPath), { recursive: true });
  const script = [
    "#!/bin/sh",
    `exec ${shellQuote(process.execPath)} ${shellQuote(hostScriptPath)}`,
    "",
  ].join("\n");
  fs.writeFileSync(wrapperPath, script);
  fs.chmodSync(wrapperPath, 0o755);
  fs.chmodSync(hostScriptPath, 0o755);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function resolveInstallOrigin(argv = process.argv, env = process.env) {
  const argumentOrigin = findArgValue("--extension-origin", argv);
  if (argumentOrigin) {
    return { origin: argumentOrigin, source: "argument" };
  }
  return resolveExtensionOriginDetails({ env });
}

function findArgValue(name, argv = process.argv) {
  const prefix = `${name}=`;
  const found = argv.find((arg) => arg.startsWith(prefix));
  return found ? found.slice(prefix.length) : "";
}

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exit(1);
}

module.exports = {
  findArgValue,
  resolveInstallOrigin,
};
