#!/usr/bin/env node
"use strict";

const fs = require("fs");
const http = require("http");
const net = require("net");
const path = require("path");
const { spawn, spawnSync } = require("child_process");
const { copyNodeRuntimeDependencies } = require("./lib/copyNodeRuntimeDependencies.cjs");
const { resolveNodeRuntime } = require("./lib/nodeRuntime.cjs");
const {
  CANONICAL_EXTENSION_ORIGIN,
  extensionIdFromOrigin,
} = require("../apps/mac/shared/extensionOrigin.cjs");

const repoRoot = path.resolve(__dirname, "..");
const fixedExtensionOrigin = CANONICAL_EXTENSION_ORIGIN;
const apiKeyEnvName = ["GEMINI", "API", "KEY"].join("_");

main().catch((error) => {
  console.error(`FAIL mimi_app_package ${error.message}`);
  process.exit(1);
});

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const runId = new Date().toISOString().replace(/[-:.]/g, "").replace("T", "-").slice(0, 15);
  const distRoot = path.resolve(options.dist || path.join(repoRoot, "dist", `mimi-app-package-${runId}`));
  const appRoot = path.join(distRoot, "Mimi.app");
  const contentsDir = path.join(appRoot, "Contents");
  const macOSDir = path.join(contentsDir, "MacOS");
  const resourcesDir = path.join(contentsDir, "Resources");
  const supportDir = path.join(distRoot, "app-support");
  const noNodePath = path.join(distRoot, "no-node-path");
  const bundledNode = path.join(resourcesDir, "node", "bin", "node");
  const appExecutable = path.join(macOSDir, "Mimi");
  const localServerDir = path.join(resourcesDir, "local-server");
  const nativeHostDir = path.join(resourcesDir, "native-host");

  ensureNewDirectory(distRoot);
  fs.mkdirSync(macOSDir, { recursive: true });
  fs.mkdirSync(resourcesDir, { recursive: true });
  fs.mkdirSync(supportDir, { recursive: true });
  fs.mkdirSync(noNodePath, { recursive: true });

  const swiftExecutable = buildMimiExecutable();
  copyExecutable(swiftExecutable, appExecutable);
  writeInfoPlist(path.join(contentsDir, "Info.plist"));
  writePkgInfo(path.join(contentsDir, "PkgInfo"));
  generateAppIcon(resourcesDir);
  const nodeRuntime = await resolveNodeRuntime(options);
  copyRuntime(nodeRuntime.nodePath, bundledNode);
  const localServerSource = path.join(repoRoot, "apps", "mac", "local-server");
  copyProjectTree(localServerSource, localServerDir);
  copyNodeRuntimeDependencies(localServerSource, localServerDir);
  copyProjectTree(path.join(repoRoot, "apps", "mac", "native-host"), nativeHostDir);
  copyProjectTree(path.join(repoRoot, "apps", "mac", "shared"), path.join(resourcesDir, "shared"));
  copyProjectTree(path.join(repoRoot, "apps", "mac", "extension"), path.join(resourcesDir, "extension"));
  writeExtensionOrigin(path.join(resourcesDir, "extension-origin.json"), options.extensionOrigin || fixedExtensionOrigin);

  if (options.smoke !== false) {
    await smokePackage({
      appExecutable,
      bundledNode,
      localServerDir,
      nativeHostDir,
      supportDir,
      noNodePath,
      extensionOrigin: options.extensionOrigin || fixedExtensionOrigin,
      smokeRemoveResource: options.smokeRemoveResource,
    });
  }

  console.log("PASS mimi_app_package");
  console.log(`dist: ${distRoot}`);
  console.log(`app: ${appRoot}`);
  console.log(`node: ${bundledNode}`);
  console.log(`nodeSource: ${nodeRuntime.source}`);
}

function parseArgs(args) {
  const options = { nodeRuntimeCache: path.join(repoRoot, "dist", "node-runtime-cache") };
  for (const arg of args) {
    if (arg.startsWith("--node=")) options.node = arg.slice("--node=".length);
    if (arg.startsWith("--dist=")) options.dist = arg.slice("--dist=".length);
    if (arg.startsWith("--node-runtime-cache=")) options.nodeRuntimeCache = arg.slice("--node-runtime-cache=".length);
    if (arg.startsWith("--extension-origin=")) options.extensionOrigin = arg.slice("--extension-origin=".length);
    if (arg.startsWith("--smoke-remove-resource=")) {
      options.smokeRemoveResource = arg.slice("--smoke-remove-resource=".length);
    }
    if (arg === "--no-smoke") options.smoke = false;
  }
  return options;
}

function buildMimiExecutable() {
  runChecked("swift build release", "swift", [
    "build",
    "--package-path",
    "apps/mac/MimiApp",
    "--configuration",
    "release",
  ], { cwd: repoRoot, timeoutMs: 120000 });
  const binPath = runChecked("swift show bin path", "swift", [
    "build",
    "--package-path",
    "apps/mac/MimiApp",
    "--configuration",
    "release",
    "--show-bin-path",
  ], { cwd: repoRoot, timeoutMs: 30000 }).stdout.trim();
  const executable = path.join(binPath, "MimiApp");
  if (!fs.existsSync(executable)) {
    throw new Error(`missing_swift_executable: ${executable}`);
  }
  return executable;
}

function copyExecutable(source, destination) {
  fs.copyFileSync(source, destination);
  fs.chmodSync(destination, 0o755);
}

function writeInfoPlist(filePath) {
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Mimi Setup for Chrome</string>
  <key>CFBundleExecutable</key>
  <string>Mimi</string>
  <key>CFBundleIdentifier</key>
  <string>com.akigarage.mimi</string>
  <key>CFBundleIconFile</key>
  <string>MimiAppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Mimi Setup for Chrome</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.2</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
`;
  fs.writeFileSync(filePath, plist);
}

function writePkgInfo(filePath) {
  fs.writeFileSync(filePath, "APPL????");
}

function generateAppIcon(resourcesDir) {
  const sourceIcon = path.join(
    repoRoot,
    "apps",
    "mac",
    "MimiApp",
    "Resources",
    "MimiSetupChromeIcon.png"
  );
  if (!fs.existsSync(sourceIcon)) {
    throw new Error("missing_source_app_icon: apps/mac/MimiApp/Resources/MimiSetupChromeIcon.png");
  }
  fs.copyFileSync(sourceIcon, path.join(resourcesDir, "MimiSetupChromeIcon.png"));

  const iconset = path.join(resourcesDir, "MimiAppIcon.iconset");
  const output = path.join(resourcesDir, "MimiAppIcon.icns");
  fs.rmSync(iconset, { recursive: true, force: true });
  fs.mkdirSync(iconset, { recursive: true });

  const sizes = [
    ["icon_16x16.png", 16],
    ["icon_16x16@2x.png", 32],
    ["icon_32x32.png", 32],
    ["icon_32x32@2x.png", 64],
    ["icon_128x128.png", 128],
    ["icon_128x128@2x.png", 256],
    ["icon_256x256.png", 256],
    ["icon_256x256@2x.png", 512],
    ["icon_512x512.png", 512],
  ];

  for (const [name, size] of sizes) {
    runChecked(`app icon ${name}`, "sips", [
      "-z",
      String(size),
      String(size),
      sourceIcon,
      "--out",
      path.join(iconset, name),
    ], { cwd: repoRoot, timeoutMs: 30000 });
  }

  runChecked("app icon icns", "iconutil", [
    "-c",
    "icns",
    iconset,
    "-o",
    output,
  ], { cwd: repoRoot, timeoutMs: 30000 });
  fs.rmSync(iconset, { recursive: true, force: true });
}

function writeExtensionOrigin(filePath, extensionOrigin) {
  fs.writeFileSync(filePath, `${JSON.stringify({ extensionOrigin }, null, 2)}\n`);
}

function copyRuntime(sourceNode, destinationNode) {
  const source = fs.realpathSync(path.resolve(sourceNode));
  fs.mkdirSync(path.dirname(destinationNode), { recursive: true });
  fs.copyFileSync(source, destinationNode);
  fs.chmodSync(destinationNode, 0o755);
}

function copyProjectTree(sourceDir, destinationDir) {
  fs.cpSync(sourceDir, destinationDir, {
    recursive: true,
    filter: (source) => shouldCopyPath(source, sourceDir),
  });
}

function shouldCopyPath(source, root) {
  const relativePath = path.relative(root, source);
  if (!relativePath) return true;
  const parts = relativePath.split(path.sep);
  if (
    parts.includes("node_modules")
    || parts.includes("tmp")
    || parts.includes("logs")
    || parts.includes(".build")
    || parts.includes("coverage")
    || parts.includes("prototype-popup")
  ) {
    return false;
  }
  const name = path.basename(source);
  if (name === ".DS_Store") return false;
  if (name === ".env" || (name.startsWith(".env.") && name !== ".env.example")) return false;
  return true;
}

async function smokePackage({ appExecutable, bundledNode, localServerDir, nativeHostDir, supportDir, noNodePath, extensionOrigin, smokeRemoveResource }) {
  if (smokeRemoveResource) {
    removeBundleResourceForSmoke(path.dirname(localServerDir), smokeRemoveResource);
  }
  runChecked("bundle smoke check", appExecutable, ["--bundle-smoke-check"], { cwd: path.dirname(appExecutable) });
  runChecked("bundled node version", bundledNode, ["--version"], { cwd: path.dirname(bundledNode) });
  assertNoNodeOnPath(noNodePath);

  const smokePort = await getFreePort();
  const smokeEnv = makeSmokeEnv({ supportDir, noNodePath, port: smokePort, extensionOrigin });
  await smokeLocalServer({ bundledNode, localServerDir, env: smokeEnv, port: smokePort, extensionOrigin });
  smokeNativeHost({ bundledNode, nativeHostDir, env: smokeEnv, supportDir, extensionOrigin });
  await smokeFakeGeminiDiagnostics({ bundledNode, localServerDir, env: smokeEnv });

  const copiedEnv = findCopiedEnvFiles(path.dirname(localServerDir));
  if (copiedEnv.length > 0) {
    throw new Error(`copied_local_env_files: ${copiedEnv.join(",")}`);
  }
}

function removeBundleResourceForSmoke(resourcesDir, relativePath) {
  if (!relativePath || path.isAbsolute(relativePath) || relativePath.split(/[\\/]/).includes("..")) {
    throw new Error(`invalid_smoke_remove_resource: ${relativePath || "missing"}`);
  }
  const target = path.join(resourcesDir, relativePath);
  if (!fs.existsSync(target)) {
    throw new Error(`smoke_remove_resource_missing: ${relativePath}`);
  }
  fs.rmSync(target, { recursive: true, force: true });
}

async function smokeLocalServer({ bundledNode, localServerDir, env, port, extensionOrigin }) {
  const child = spawn(bundledNode, ["src/server.js"], {
    cwd: localServerDir,
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk.toString("utf8"); });
  child.stderr.on("data", (chunk) => { output += chunk.toString("utf8"); });

  try {
    const status = await waitForStatus(port, 7000);
    if (!status.ok || status.service !== "jp-dub-local-server") {
      throw new Error(`unexpected_status: ${JSON.stringify(status)}`);
    }
    if (!status.realModeReady) throw new Error("status_real_mode_not_ready");
    if (status.allowedExtensionId !== extensionIdFromOrigin(extensionOrigin)) {
      throw new Error(`status_extension_id_mismatch: ${status.allowedExtensionId || "missing"}`);
    }
  } finally {
    child.kill("SIGTERM");
    await waitForExit(child, 2500).catch(() => child.kill("SIGKILL"));
  }

  if (child.exitCode && child.exitCode !== 0) {
    throw new Error(`local_server_exit_${child.exitCode}: ${sanitize(output)}`);
  }
}

function smokeNativeHost({ bundledNode, nativeHostDir, env, supportDir, extensionOrigin }) {
  runChecked("native host install", bundledNode, [
    "scripts/install.js",
    `--extension-origin=${extensionOrigin}`,
  ], { cwd: nativeHostDir, env });

  const wrapperPath = path.join(
    supportDir,
    "home",
    "Library",
    "Application Support",
    "JP Dub",
    "NativeHost",
    "jp-dub-native-host",
  );
  const wrapper = fs.readFileSync(wrapperPath, "utf8");
  if (!wrapper.includes(bundledNode)) {
    throw new Error("native_host_wrapper_does_not_reference_bundled_node");
  }

  const doctor = runChecked("native host doctor", bundledNode, ["scripts/doctor.js"], { cwd: nativeHostDir, env });
  if (!doctor.stdout.includes("host ping: ok")) {
    throw new Error(`native_host_ping_missing: ${sanitize(doctor.stdout || doctor.stderr)}`);
  }
}

async function smokeFakeGeminiDiagnostics({ bundledNode, localServerDir, env }) {
  const fakeGemini = await startFakeGeminiServer(localServerDir);
  const endpoint = `ws://127.0.0.1:${fakeGemini.address().port}/ws`;
  const diagnosticEnv = { ...env, JP_DUB_GEMINI_ENDPOINT: endpoint };
  try {
    const setup = await runCheckedAsync("fake Gemini diagnose-real", bundledNode, ["scripts/diagnose-real.js"], {
      cwd: localServerDir,
      env: diagnosticEnv,
      timeoutMs: 15000,
    });
    if (!setup.stdout.includes("PASS setup_complete")) {
      throw new Error(`diagnose_real_failed: ${sanitize(setup.stdout || setup.stderr)}`);
    }

    const pcmPath = path.join(path.dirname(localServerDir), "diagnose-smoke-16khz.pcm");
    fs.writeFileSync(pcmPath, Buffer.alloc(16000 * 2 / 10));
    const stream = await runCheckedAsync("fake Gemini diagnose-stream", bundledNode, ["scripts/diagnose-stream.js", pcmPath], {
      cwd: localServerDir,
      env: diagnosticEnv,
      timeoutMs: 30000,
    });
    if (!stream.stdout.includes("PASS stream") || !stream.stdout.match(/"outputBytes":[1-9]/)) {
      throw new Error(`diagnose_stream_failed: ${sanitize(stream.stdout || stream.stderr)}`);
    }
  } finally {
    await closeServer(fakeGemini);
  }
}

function startFakeGeminiServer(localServerDir) {
  const { attachWebSocketServer } = require(path.join(localServerDir, "src", "websocket"));
  const server = http.createServer();
  attachWebSocketServer(server, {
    path: "/ws",
    isAllowedOrigin: () => true,
    onConnection: (peer) => {
      peer.onMessage((frame) => {
        const message = JSON.parse(frame.payload.toString("utf8"));
        if (message.setup) {
          peer.sendText({ setupComplete: {} });
          return;
        }
        if (message.realtimeInput?.audio?.data) {
          peer.sendText({
            serverContent: {
              outputTranscription: { text: "テスト", languageCode: "ja" },
              modelTurn: {
                parts: [
                  { inlineData: { data: Buffer.alloc(240).toString("base64") } },
                ],
              },
            },
          });
        }
      });
    },
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)));
}

function closeServer(server) {
  return new Promise((resolve) => server.close(resolve));
}

function makeSmokeEnv({ supportDir, noNodePath, port, extensionOrigin }) {
  const envDir = path.join(supportDir, "local-server");
  const usageDir = path.join(supportDir, "tmp");
  fs.mkdirSync(envDir, { recursive: true });
  fs.mkdirSync(usageDir, { recursive: true });
  return {
    HOME: path.join(supportDir, "home"),
    PATH: noNodePath,
    JP_DUB_ENV_FILE: path.join(envDir, ".env"),
    JP_DUB_USAGE_FILE: path.join(usageDir, "jp-dub-usage.json"),
    JP_DUB_PORT: String(port),
    JP_DUB_IDLE_EXIT_SECONDS: "5",
    JP_DUB_MONTHLY_LIMIT_MINUTES: "30",
    JP_DUB_TARGET_LANGUAGE: "ja",
    MIMI_EXTENSION_ORIGIN: extensionOrigin,
    [apiKeyEnvName]: "dummy-mimi-app-package-smoke-value",
  };
}

function assertNoNodeOnPath(noNodePath) {
  const probe = spawnSync("node", ["--version"], {
    env: { PATH: noNodePath },
    encoding: "utf8",
  });
  if (!probe.error) {
    throw new Error(`system_node_still_on_path: ${sanitize(probe.stdout || probe.stderr)}`);
  }
}

function findCopiedEnvFiles(root) {
  const found = [];
  walk(root, (filePath) => {
    const name = path.basename(filePath);
    if (name === ".env" || (name.startsWith(".env.") && name !== ".env.example")) {
      found.push(path.relative(root, filePath));
    }
  });
  return found;
}

function walk(dir, visit) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const filePath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(filePath, visit);
    } else {
      visit(filePath);
    }
  }
}

function ensureNewDirectory(dirPath) {
  if (fs.existsSync(dirPath)) {
    throw new Error(`dist_already_exists: ${dirPath}`);
  }
  fs.mkdirSync(dirPath, { recursive: true });
}

function runChecked(label, command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env || process.env,
    encoding: "utf8",
    timeout: options.timeoutMs || 7000,
  });
  if (result.error) throw new Error(`${label}: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`${label}: ${path.basename(command)} ${args.join(" ")} exited ${result.status}: ${sanitize(result.stdout || result.stderr)}`);
  }
  return result;
}

function runCheckedAsync(label, command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env || process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`${label}: timeout`));
    }, options.timeoutMs || 7000);
    child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(new Error(`${label}: ${error.message}`));
    });
    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) {
        resolve({ stdout, stderr, status: code });
        return;
      }
      reject(new Error(`${label}: ${path.basename(command)} ${args.join(" ")} exited ${code}: ${sanitize(stdout || stderr)}`));
    });
  });
}

function getFreePort() {
  const server = net.createServer();
  return new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      server.close(() => resolve(port));
    });
  });
}

function waitForStatus(port, timeoutMs) {
  const startedAt = Date.now();
  return new Promise((resolve, reject) => {
    const tick = () => {
      fetchJson(`http://127.0.0.1:${port}/status`)
        .then(resolve)
        .catch((error) => {
          if (Date.now() - startedAt >= timeoutMs) {
            reject(new Error(`status_timeout: ${error.message}`));
            return;
          }
          setTimeout(tick, 200);
        });
    };
    tick();
  });
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          reject(new Error(`non_json_status_${response.statusCode}`));
        }
      });
    });
    request.on("error", reject);
    request.setTimeout(900, () => request.destroy(new Error("status_timeout")));
  });
}

function waitForExit(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("process_exit_timeout")), timeoutMs);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function sanitize(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, 500);
}
