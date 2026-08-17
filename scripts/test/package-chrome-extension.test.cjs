#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const repoRoot = path.resolve(__dirname, "..", "..");
const packageScript = path.join(repoRoot, "scripts", "package-chrome-extension.cjs");
const sourceManifestPath = path.join(repoRoot, "apps", "mac", "extension", "manifest.json");

test("Store ZIP omits manifest.key while the source keeps the canonical Store identity", (t) => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-store-package-test-"));
  const outDir = path.join(tempRoot, "package");
  t.after(() => fs.rmSync(tempRoot, { recursive: true, force: true }));

  const result = spawnSync(process.execPath, [packageScript, `--out=${outDir}`], {
    cwd: repoRoot,
    encoding: "utf8",
    env: {
      ...process.env,
      MIMI_EXTENSION_ORIGIN: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    },
    timeout: 30000,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);

  const sourceManifest = readJson(sourceManifestPath);
  const stagedManifest = readJson(path.join(outDir, "stage", "manifest.json"));
  const report = readJson(path.join(outDir, "preflight-report.json"));
  const zipPath = path.join(outDir, `mimi-chrome-extension-${stagedManifest.version}.zip`);
  const zippedManifest = readZipManifest(zipPath);

  assert.equal(Object.hasOwn(sourceManifest, "key"), true);
  assert.equal(Object.hasOwn(stagedManifest, "key"), false);
  assert.equal(Object.hasOwn(zippedManifest, "key"), false);
  assert.equal(sourceManifest.version, "0.1.3");
  assert.equal(stagedManifest.version, "0.1.3");
  assert.equal(zippedManifest.version, "0.1.3");
  assert.equal(report.version, "0.1.3");
  assert.equal(report.storeManifestHasKey, false);
  assert.equal(report.extensionId, "oknekoaclmnljnlpmffphpiflcdeibgg");
});

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function readZipManifest(zipPath) {
  const result = spawnSync("unzip", ["-p", zipPath, "manifest.json"], {
    encoding: "utf8",
    timeout: 30000,
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
