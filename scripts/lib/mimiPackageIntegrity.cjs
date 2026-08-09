"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

function collectLocalArtifactEvidence(workRoot) {
  const chromeZip = findChromeZip(path.join(workRoot, "chrome-package"));
  const mimiApp = path.join(workRoot, "app-package", "Mimi.app");
  if (!chromeZip || !fs.existsSync(mimiApp)) throw new Error("missing_local_package_evidence");
  const expected = {
    chromeZipSHA256: sha256File(chromeZip),
    mimiAppTreeSHA256: hashDirectory(mimiApp),
  };
  const before = verifyLocalArtifacts({ chromeZip, mimiApp }, expected);
  if (before.length) throw new Error("clean_package_integrity_failed");

  fs.appendFileSync(chromeZip, "mimi-tamper-negative");
  fs.appendFileSync(path.join(mimiApp, "Contents", "Info.plist"), "mimi-tamper-negative");
  const rejected = verifyLocalArtifacts({ chromeZip, mimiApp }, expected).sort();
  return {
    ...expected,
    tamperRejected: rejected.join(",") === "chrome_zip,mimi_app",
  };
}

function verifyLocalArtifacts(paths, expected) {
  const mismatches = [];
  if (sha256File(paths.chromeZip) !== expected.chromeZipSHA256) mismatches.push("chrome_zip");
  if (hashDirectory(paths.mimiApp) !== expected.mimiAppTreeSHA256) mismatches.push("mimi_app");
  return mismatches;
}

function findChromeZip(root) {
  if (!fs.existsSync(root)) return "";
  return walkFiles(root).find((filePath) => filePath.endsWith(".zip")) || "";
}

function hashDirectory(root) {
  if (fs.lstatSync(root).isSymbolicLink()) throw new Error("unsupported_package_file_type:root_symlink");
  const hasher = crypto.createHash("sha256");
  for (const filePath of walkFiles(root).sort()) {
    const relative = path.relative(root, filePath);
    hasher.update(`${Buffer.byteLength(relative)}:${relative}:`);
    hasher.update(fs.readFileSync(filePath));
  }
  return hasher.digest("hex");
}

function sha256File(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function walkFiles(root) {
  const files = [];
  for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
    const filePath = path.join(root, entry.name);
    if (entry.isDirectory()) files.push(...walkFiles(filePath));
    else if (entry.isFile()) files.push(filePath);
    else throw new Error(`unsupported_package_file_type:${entry.name}`);
  }
  return files;
}

module.exports = {
  collectLocalArtifactEvidence,
  hashDirectory,
  verifyLocalArtifacts,
};
