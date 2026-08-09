#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const {
  CANONICAL_EXTENSION_ID,
  resolveExtensionOriginDetails,
} = require("../apps/mac/shared/extensionOrigin.cjs");

const repoRoot = path.resolve(__dirname, "..");
const extensionDir = path.join(repoRoot, "apps", "mac", "extension");
const expectedExtensionId = CANONICAL_EXTENSION_ID;
const requiredPermissions = ["activeTab", "nativeMessaging", "offscreen", "storage", "tabCapture"];
const requiredHostPermissions = ["http://127.0.0.1/*", "http://localhost/*"];
const copiedRoots = ["manifest.json", "src", "icons", "_locales"];

main().catch((error) => {
  console.error(`FAIL chrome_extension_package ${error.message}`);
  process.exit(1);
});

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const runId = new Date().toISOString().replace(/[-:.]/g, "").replace("T", "-").slice(0, 15);
  const outDir = path.resolve(options.out || path.join(repoRoot, "dist", `mimi-chrome-extension-${runId}`));
  const stageDir = path.join(outDir, "stage");

  ensureNewDirectory(outDir);
  fs.mkdirSync(stageDir, { recursive: true });
  const sourceOriginDetails = resolveExtensionOriginDetails({
    manifestPath: path.join(extensionDir, "manifest.json"),
    env: {},
  });
  copyExtensionFiles(stageDir);

  const manifestPath = path.join(stageDir, "manifest.json");
  prepareStoreManifest(manifestPath);
  const manifest = readJson(manifestPath);
  const report = validatePackage({ manifest, stageDir, sourceOriginDetails });
  const zipPath = path.join(outDir, `mimi-chrome-extension-${manifest.version}.zip`);
  createZip({ stageDir, zipPath });
  validateZip(zipPath);
  fs.writeFileSync(path.join(outDir, "preflight-report.json"), `${JSON.stringify(report, null, 2)}\n`);

  console.log("PASS chrome_extension_package");
  console.log(`dist: ${outDir}`);
  console.log(`zip: ${zipPath}`);
  console.log(`version: ${manifest.version}`);
  console.log(`extensionId: ${report.extensionId}`);
  console.log(`origin: ${report.extensionOrigin}`);
}

function parseArgs(args) {
  const options = {};
  for (const arg of args) {
    if (arg.startsWith("--out=")) options.out = arg.slice("--out=".length);
  }
  return options;
}

function copyExtensionFiles(stageDir) {
  for (const root of copiedRoots) {
    const source = path.join(extensionDir, root);
    const destination = path.join(stageDir, root);
    if (!fs.existsSync(source)) throw new Error(`missing_extension_source: ${source}`);
    fs.cpSync(source, destination, {
      recursive: true,
      filter: shouldCopyPath,
    });
  }
}

function prepareStoreManifest(manifestPath) {
  const manifest = readJson(manifestPath);
  delete manifest.key;
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

function shouldCopyPath(source) {
  const relativePath = path.relative(extensionDir, source);
  if (!relativePath) return true;
  const parts = relativePath.split(path.sep);
  if (parts.includes("prototype-popup") || parts.includes("test") || parts.includes("node_modules")) return false;
  const name = path.basename(source);
  if (name === ".DS_Store") return false;
  if (name === "package.json" || name === "package-lock.json") return false;
  if (name === ".env" || (name.startsWith(".env.") && name !== ".env.example")) return false;
  return true;
}

function validatePackage({ manifest, stageDir, sourceOriginDetails }) {
  assertEqual(manifest.manifest_version, 3, "manifest_version");
  assertString(manifest.name, "name");
  assertString(manifest.version, "version");
  assertString(manifest.description, "description");
  if (manifest.name.length > 75) throw new Error("manifest_name_too_long");
  if (manifest.description.length > 132) throw new Error("manifest_description_too_long");
  assertObject(manifest.icons, "icons");
  assertObject(manifest.action, "action");
  assertObject(manifest.background, "background");
  assertArray(manifest.permissions, "permissions");
  assertArray(manifest.host_permissions, "host_permissions");
  if (Object.hasOwn(manifest, "key")) throw new Error("store_manifest_contains_key");

  assertPermissionSet(manifest.permissions, requiredPermissions, "permissions");
  assertPermissionSet(manifest.host_permissions, requiredHostPermissions, "host_permissions");
  assertEqual(manifest.background.service_worker, "src/service-worker.js", "background.service_worker");
  assertEqual(manifest.action.default_popup, "src/popup.html", "action.default_popup");
  for (const size of ["16", "32", "48", "128"]) {
    assertExistingFile(stageDir, manifest.icons[size], `icons.${size}`);
  }
  for (const size of ["16", "32", "48", "128"]) {
    assertExistingFile(stageDir, manifest.action.default_icon[size], `action.default_icon.${size}`);
  }
  for (const file of [
    "manifest.json",
    "_locales/en/messages.json",
    "_locales/ja/messages.json",
    "src/capture-worklet.js",
    "src/languages.js",
    "src/offscreen.html",
    "src/offscreen.js",
    "src/popup.css",
    "src/popup.html",
    "src/popup.js",
    "src/service-worker.js",
  ]) {
    assertExistingFile(stageDir, file, file);
  }

  if (sourceOriginDetails.extensionId !== expectedExtensionId) {
    throw new Error(`extension_id_mismatch: ${sourceOriginDetails.extensionId}`);
  }
  assertNoForbiddenPackageFiles(stageDir);
  assertNoSecretLikeText(stageDir);

  return {
    manifestVersion: manifest.manifest_version,
    name: manifest.name,
    version: manifest.version,
    extensionId: sourceOriginDetails.extensionId,
    extensionOrigin: sourceOriginDetails.origin,
    originSource: sourceOriginDetails.source,
    storeManifestHasKey: false,
    permissions: manifest.permissions,
    hostPermissions: manifest.host_permissions,
    copiedRoots,
    excluded: ["prototype-popup", "test", "node_modules", "package.json", "package-lock.json", ".env", ".env.*"],
    notes: [
      "Chrome Web Store upload and managed distribution still require a human-controlled dashboard or policy step.",
      "The Store ZIP omits manifest.key; the source manifest keeps the Dashboard public key so unpacked and Store IDs match.",
      "Native host allowed_origins must match the canonical Chrome Web Store extension ID.",
    ],
  };
}

function createZip({ stageDir, zipPath }) {
  const zip = spawnSync("zip", ["-qr", zipPath, "."], {
    cwd: stageDir,
    encoding: "utf8",
    timeout: 30000,
  });
  if (zip.error) throw new Error(`zip_failed: ${zip.error.message}`);
  if (zip.status !== 0) throw new Error(`zip_failed_${zip.status}: ${sanitize(zip.stdout || zip.stderr)}`);
}

function validateZip(zipPath) {
  const listing = spawnSync("unzip", ["-Z1", zipPath], {
    encoding: "utf8",
    timeout: 30000,
  });
  if (listing.error) throw new Error(`zip_listing_failed: ${listing.error.message}`);
  if (listing.status !== 0) throw new Error(`zip_listing_failed_${listing.status}: ${sanitize(listing.stdout || listing.stderr)}`);
  const entries = listing.stdout.trim().split(/\n+/).filter(Boolean);
  if (!entries.includes("manifest.json")) throw new Error("zip_missing_root_manifest");
  for (const entry of entries) {
    if (entry.startsWith("stage/")) throw new Error(`zip_contains_stage_parent: ${entry}`);
    if (entry.includes("prototype-popup/") || entry.startsWith("test/") || entry.includes("/test/")) {
      throw new Error(`zip_contains_dev_only_file: ${entry}`);
    }
    const name = path.basename(entry);
    if (name === ".env" || name.startsWith(".env.") || name === "package.json" || name === "package-lock.json") {
      throw new Error(`zip_contains_forbidden_file: ${entry}`);
    }
  }

  const manifestRead = spawnSync("unzip", ["-p", zipPath, "manifest.json"], {
    encoding: "utf8",
    timeout: 30000,
  });
  if (manifestRead.error) throw new Error(`zip_manifest_read_failed: ${manifestRead.error.message}`);
  if (manifestRead.status !== 0) {
    throw new Error(`zip_manifest_read_failed_${manifestRead.status}: ${sanitize(manifestRead.stderr)}`);
  }
  const zipManifest = JSON.parse(manifestRead.stdout);
  if (Object.hasOwn(zipManifest, "key")) throw new Error("zip_manifest_contains_key");
}

function assertNoForbiddenPackageFiles(root) {
  for (const filePath of walkFiles(root)) {
    const relativePath = path.relative(root, filePath);
    const parts = relativePath.split(path.sep);
    const name = path.basename(filePath);
    if (parts.includes("prototype-popup") || parts.includes("test") || parts.includes("node_modules")) {
      throw new Error(`packaged_dev_only_file: ${relativePath}`);
    }
    if (name === ".env" || name.startsWith(".env.") || name === "package.json" || name === "package-lock.json") {
      throw new Error(`packaged_forbidden_file: ${relativePath}`);
    }
  }
}

function assertNoSecretLikeText(root) {
  const patterns = [
    /GEMINI_API_KEY/,
    /BEGIN (?:RSA|OPENSSH|PRIVATE) KEY/i,
    /authorization\s*:/i,
    /bearer\s+[A-Za-z0-9._-]{20,}/i,
    /AIza[0-9A-Za-z_-]{20,}/,
  ];
  for (const filePath of walkFiles(root)) {
    if (!isTextFile(filePath)) continue;
    const text = fs.readFileSync(filePath, "utf8");
    if (patterns.some((pattern) => pattern.test(text))) {
      throw new Error(`secret_like_text_in_package: ${path.relative(root, filePath)}`);
    }
  }
}

function walkFiles(dirPath) {
  const files = [];
  for (const entry of fs.readdirSync(dirPath, { withFileTypes: true })) {
    const filePath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFiles(filePath));
    } else {
      files.push(filePath);
    }
  }
  return files;
}

function isTextFile(filePath) {
  return [".css", ".html", ".js", ".json", ".svg"].includes(path.extname(filePath));
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function assertExistingFile(root, relativePath, label) {
  if (!relativePath || relativePath.includes("..") || path.isAbsolute(relativePath)) {
    throw new Error(`invalid_relative_path: ${label}`);
  }
  const filePath = path.join(root, relativePath);
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    throw new Error(`missing_package_file: ${label}:${relativePath}`);
  }
}

function assertPermissionSet(actual, expected, label) {
  const actualSorted = [...actual].sort();
  const expectedSorted = [...expected].sort();
  if (actualSorted.join("\n") !== expectedSorted.join("\n")) {
    throw new Error(`${label}_mismatch: expected ${expectedSorted.join(",")} got ${actualSorted.join(",")}`);
  }
}

function assertObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`invalid_${label}`);
}

function assertArray(value, label) {
  if (!Array.isArray(value)) throw new Error(`invalid_${label}`);
}

function assertString(value, label) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`invalid_${label}`);
}

function assertEqual(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}_mismatch: expected ${expected} got ${actual}`);
}

function ensureNewDirectory(dirPath) {
  if (fs.existsSync(dirPath)) throw new Error(`dist_already_exists: ${dirPath}`);
  fs.mkdirSync(dirPath, { recursive: true });
}

function sanitize(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, 500);
}
