"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const repoRoot = path.resolve(__dirname, "../..");

test("Chrome setup helper and standalone Mac app expose distinct identities", () => {
  const helperApp = read("apps/mac/MimiApp/Sources/MimiApp/MimiApp.swift");
  const helperView = read("apps/mac/MimiApp/Sources/MimiApp/ContentView.swift");
  const helperModel = read("apps/mac/MimiApp/Sources/MimiApp/SetupViewModel.swift");
  const packageScript = read("scripts/package-mimi-app.cjs");
  const standaloneApp = read("apps/mac/MimiForMac/Sources/MimiForMacDebug/main.swift");
  const standaloneView = read("apps/mac/MimiForMac/Sources/MimiForMacDebug/MimiMainView.swift");
  const standalonePlist = read("apps/mac/MimiForMac/Packaging/Info.plist");

  assert.match(helperApp, /WindowGroup\("Mimi Setup for Chrome"\)/);
  assert.match(helperView, /Text\("Mimi Setup for Chrome"\)/);
  assert.match(helperModel, /MimiSetupChromeIcon\.png/);
  assert.match(packageScript, /<string>Mimi Setup for Chrome<\/string>/);
  assert.match(packageScript, /MimiApp.*Resources.*MimiSetupChromeIcon\.png/s);
  assert.match(standaloneApp, /WindowGroup\("Mimi for Mac", id: "main"\)/);
  assert.match(standaloneView, /Text\("Mimi for Mac"\)/);
  assert.equal(count(standalonePlist, "<string>Mimi for Mac</string>"), 2);
});

test("helper icon is a dedicated high resolution asset", () => {
  const helperIcon = file("apps/mac/MimiApp/Resources/MimiSetupChromeIcon.png");
  const extensionIcon = file("apps/mac/extension/icons/icon-128.png");
  const standaloneIcon = file("apps/mac/MimiForMac/Packaging/MimiAppIcon.png");

  assert.ok(fs.existsSync(helperIcon), "missing helper icon");
  assert.deepEqual(pngDimensions(helperIcon), { width: 1024, height: 1024 });
  assert.notEqual(sha256(helperIcon), sha256(extensionIcon));
  assert.notEqual(sha256(helperIcon), sha256(standaloneIcon));
});

function read(relativePath) {
  return fs.readFileSync(file(relativePath), "utf8");
}

function file(relativePath) {
  return path.join(repoRoot, relativePath);
}

function count(text, needle) {
  return text.split(needle).length - 1;
}

function sha256(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

function pngDimensions(filePath) {
  const bytes = fs.readFileSync(filePath);
  assert.equal(bytes.subarray(1, 4).toString("ascii"), "PNG");
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}
