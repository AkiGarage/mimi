"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const {
  buildCommandPlan,
  inspectDependencies,
  makeIntegrityManifest,
  runSecurityGate,
  verifyIntegrityManifest,
} = require("../lib/mimiSecurityGate.cjs");
const { collectLocalArtifactEvidence, hashDirectory } = require("../lib/mimiPackageIntegrity.cjs");

const repoRoot = path.resolve(__dirname, "..", "..");

function makeDependencyFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-dependencies-"));
  for (const relative of [
    "apps/mac/extension/package.json",
    "apps/mac/local-server/package.json",
    "apps/mac/local-server/package-lock.json",
    "apps/mac/native-host/package.json",
    "apps/mac/MimiApp/Package.swift",
    "scripts/mimi-node-runtime.json",
  ]) {
    const destination = path.join(root, relative);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.copyFileSync(path.join(repoRoot, relative), destination);
  }
  return root;
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

test("security gate uses a fixed shell-free validation plan", () => {
  const plan = buildCommandPlan(repoRoot, "/tmp/mimi-security-work");

  assert.ok(plan.length >= 8);
  assert.equal(new Set(plan.map((check) => check.id)).size, plan.length);
  for (const check of plan) {
    assert.equal(typeof check.command, "string");
    assert.equal(path.isAbsolute(check.command), true);
    assert.ok(Array.isArray(check.args));
    assert.equal(check.shell, false);
    assert.ok(check.cwd.startsWith(repoRoot));
  }
  assert.equal(plan.some((check) => check.args.join(" ").includes("$")), false);
  assert.equal(plan.some((check) => ["npm", "swift", "git"].includes(check.command)), false);
});

test("dependency inspection accepts the reviewed exact ws package and lockfile", () => {
  assert.deepEqual(inspectDependencies(repoRoot).problems, []);
});

test("dependency inspection rejects ranged and unreviewed runtime dependencies", () => {
  const root = makeDependencyFixture();
  try {
    const manifestPath = path.join(root, "apps/mac/local-server/package.json");
    const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    manifest.dependencies = { ws: "^8.21.1", "left-pad": "1.3.0" };
    writeJson(manifestPath, manifest);

    const problems = inspectDependencies(root).problems;
    assert.ok(problems.includes("apps/mac/local-server/package.json:runtime_dependency_not_exact:ws"));
    assert.ok(problems.includes("apps/mac/local-server/package.json:runtime_dependency_not_allowlisted:left-pad"));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("dependency inspection rejects mismatched, incomplete, and extra lock entries", () => {
  const root = makeDependencyFixture();
  try {
    const lockPath = path.join(root, "apps/mac/local-server/package-lock.json");
    const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
    lock.packages[""].dependencies.ws = "8.21.0";
    lock.packages["node_modules/ws"].version = "8.21.0";
    lock.packages["node_modules/ws"].resolved = "https://example.com/ws.tgz";
    delete lock.packages["node_modules/ws"].integrity;
    lock.packages["node_modules/unreviewed"] = { version: "1.0.0" };
    writeJson(lockPath, lock);

    const problems = inspectDependencies(root).problems;
    assert.ok(problems.includes("apps/mac/local-server/package-lock.json:root_dependency_mismatch:ws"));
    assert.ok(problems.includes("apps/mac/local-server/package-lock.json:locked_version_mismatch:ws"));
    assert.ok(problems.includes("apps/mac/local-server/package-lock.json:resolved_source_mismatch:ws"));
    assert.ok(problems.includes("apps/mac/local-server/package-lock.json:integrity_mismatch:ws"));
    assert.ok(
      problems.includes("apps/mac/local-server/package-lock.json:unexpected_package:node_modules/unreviewed")
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("integrity manifest rejects a tampered release file", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-security-integrity-"));
  try {
    fs.writeFileSync(path.join(root, "candidate.txt"), "approved\n");
    const manifest = makeIntegrityManifest(root, ["candidate.txt"]);
    assert.deepEqual(verifyIntegrityManifest(root, manifest), []);

    fs.writeFileSync(path.join(root, "candidate.txt"), "tampered\n");
    assert.deepEqual(verifyIntegrityManifest(root, manifest), ["candidate.txt"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("generated Chrome ZIP and Mimi.app checksums reject actual package tampering", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-package-tamper-"));
  try {
    const chromeDir = path.join(root, "chrome-package");
    const appContents = path.join(root, "app-package", "Mimi.app", "Contents");
    fs.mkdirSync(chromeDir, { recursive: true });
    fs.mkdirSync(appContents, { recursive: true });
    fs.writeFileSync(path.join(chromeDir, "mimi.zip"), "clean-zip");
    fs.writeFileSync(path.join(appContents, "Info.plist"), "clean-app");

    const evidence = collectLocalArtifactEvidence(root);

    assert.match(evidence.chromeZipSHA256, /^[a-f0-9]{64}$/);
    assert.match(evidence.mimiAppTreeSHA256, /^[a-f0-9]{64}$/);
    assert.equal(evidence.tamperRejected, true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("Mimi.app tree hashing rejects symlink additions", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-package-symlink-"));
  try {
    const appRoot = path.join(root, "Mimi.app");
    fs.mkdirSync(appRoot);
    fs.writeFileSync(path.join(appRoot, "Info.plist"), "clean-app");
    fs.symlinkSync("Info.plist", path.join(appRoot, "unexpected-link"));

    assert.throws(() => hashDirectory(appRoot), /unsupported_package_file_type/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("security gate emits one secret-free PASS report with zero in-scope findings", async () => {
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-security-report-"));
  const privateNeedle = ["private", "local", "value"].join("-");
  try {
    const result = await runSecurityGate({
      repoRoot,
      outputDir,
      runCommand: (check) => ({
        status: 0,
        stdout: `PASS ${check.id} ${privateNeedle}`,
        stderr: "",
      }),
    });

    assert.equal(result.report.gate, "PASS");
    assert.equal(result.report.candidate.canonicalOriginMatch, true);
    assert.equal(result.report.candidate.extensionId, "oknekoaclmnljnlpmffphpiflcdeibgg");
    assert.deepEqual(result.report.unresolved, { critical: 0, high: 0, medium: 0 });
    assert.ok(result.report.evidence.every((entry) => entry.status === "PASS"));
    const combined = fs.readFileSync(result.jsonPath, "utf8") + fs.readFileSync(result.markdownPath, "utf8");
    assert.doesNotMatch(combined, new RegExp(privateNeedle, "i"));
    assert.doesNotMatch(combined, new RegExp(repoRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.doesNotMatch(combined, /AIza|BEGIN PRIVATE KEY|Bearer\s+/i);
    assert.match(combined, /production_signing_notarization/);
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});

test("failed runtime evidence makes the invitation preflight NO_GO", async () => {
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-security-failure-"));
  try {
    const result = await runSecurityGate({
      repoRoot,
      outputDir,
      runCommand: (check) => ({ status: check.id === "local_server_tests" ? 1 : 0, stdout: "", stderr: "failed" }),
    });

    assert.equal(result.report.gate, "NO_GO");
    assert.equal(result.report.unresolved.high, 1);
    assert.equal(result.report.evidence.find((entry) => entry.id === "local_server_tests").status, "FAIL");
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});

test("canonical origin mismatch makes the invitation preflight NO_GO", async () => {
  const outputDir = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-security-origin-"));
  try {
    const result = await runSecurityGate({
      repoRoot,
      outputDir,
      runCommand: () => ({ status: 0, stdout: "", stderr: "" }),
      readCandidateIdentity: () => ({
        marketingVersion: "0.1.0",
        extensionId: "mismatch",
        canonicalOriginMatch: false,
        sourceEvidenceSHA256: "0".repeat(64),
      }),
    });

    assert.equal(result.report.gate, "NO_GO");
    assert.equal(result.report.unresolved.high, 1);
    assert.equal(result.report.evidence.find((entry) => entry.id === "canonical_origin_match").status, "FAIL");
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});
