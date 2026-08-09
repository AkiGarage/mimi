"use strict";

const fs = require("fs");
const crypto = require("crypto");
const https = require("https");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const manifestPath = path.join(__dirname, "..", "mimi-node-runtime.json");

async function resolveNodeRuntime(options) {
  if (options.node) {
    return { nodePath: path.resolve(options.node), source: "override" };
  }
  const manifest = readNodeRuntimeManifest();
  const runtime = selectNodeRuntime(manifest);
  const cacheRoot = path.resolve(options.nodeRuntimeCache);
  const archivePath = path.join(cacheRoot, runtime.fileName);

  fs.mkdirSync(cacheRoot, { recursive: true });
  const extractDir = fs.mkdtempSync(path.join(cacheRoot, `${runtime.version}-${runtime.platform}-${runtime.arch}-`));
  await ensureRuntimeArchive(runtime, archivePath);
  verifySha256(archivePath, runtime.sha256);
  extractRuntimeArchive(archivePath, extractDir);

  const nodePath = path.join(extractDir, runtime.folderName, "bin", "node");
  if (!fs.existsSync(nodePath)) throw new Error(`missing_pinned_node: ${nodePath}`);
  fs.chmodSync(nodePath, 0o755);
  return { nodePath, source: `${runtime.version}/${runtime.platform}-${runtime.arch}` };
}

function readNodeRuntimeManifest() {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (!manifest.version || !Array.isArray(manifest.runtimes)) {
    throw new Error(`invalid_node_runtime_manifest: ${manifestPath}`);
  }
  return manifest;
}

function selectNodeRuntime(manifest) {
  const platform = os.platform();
  const arch = os.arch();
  const runtime = manifest.runtimes.find((entry) => entry.platform === platform && entry.arch === arch);
  if (!runtime) throw new Error(`unsupported_node_runtime: ${platform}-${arch}`);
  for (const field of ["fileName", "folderName", "url", "sha256"]) {
    if (!runtime[field]) throw new Error(`invalid_node_runtime_${field}`);
  }
  return { ...runtime, version: manifest.version };
}

async function ensureRuntimeArchive(runtime, archivePath) {
  if (fs.existsSync(archivePath)) return;
  const tempPath = `${archivePath}.tmp-${process.pid}`;
  await downloadFile(runtime.url, tempPath);
  fs.renameSync(tempPath, archivePath);
}

function downloadFile(url, destination) {
  return new Promise((resolve, reject) => {
    const request = https.get(url, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error(`node_runtime_download_${response.statusCode}: ${url}`));
        return;
      }
      const file = fs.createWriteStream(destination, { mode: 0o644 });
      response.pipe(file);
      file.on("finish", () => file.close(resolve));
      file.on("error", reject);
    });
    request.on("error", reject);
    request.setTimeout(60000, () => request.destroy(new Error("node_runtime_download_timeout")));
  });
}

function verifySha256(filePath, expectedSha256) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(filePath));
  const actual = hash.digest("hex");
  if (actual !== expectedSha256) {
    throw new Error(`node_runtime_checksum_mismatch: expected ${expectedSha256} got ${actual}`);
  }
}

function extractRuntimeArchive(archivePath, destinationDir) {
  const result = spawnSync("tar", ["-xzf", archivePath, "-C", destinationDir], {
    encoding: "utf8",
    timeout: 60000,
  });
  if (result.error) throw new Error(`extract pinned node runtime: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(`extract pinned node runtime: tar exited ${result.status}: ${sanitize(result.stdout || result.stderr)}`);
  }
}

function sanitize(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, 500);
}

module.exports = { resolveNodeRuntime };
