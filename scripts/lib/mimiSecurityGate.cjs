"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { resolveExtensionOriginDetails } = require("../../apps/mac/shared/extensionOrigin.cjs");
const { buildHostManifest } = require("../../apps/mac/native-host/src/hostManifest.js");
const { collectLocalArtifactEvidence } = require("./mimiPackageIntegrity.cjs");

const REPORT_JSON = "mimi-security-gate-report.json";
const REPORT_MARKDOWN = "mimi-security-gate-report.md";
function buildCommandPlan(repoRoot, workRoot) {
  const tools = trustedTooling();
  const component = (id, cwd, command, args, category) => ({
    id,
    category,
    command,
    args,
    cwd: path.join(repoRoot, cwd),
    shell: false,
    workRoot,
  });
  const npm = (id, cwd, args, category) =>
    component(id, cwd, tools.node, [tools.npmCli, ...args], category);
  return [
    npm("extension_check", "apps/mac/extension", ["run", "check"], "audio_and_extension"),
    npm("extension_tests", "apps/mac/extension", ["test"], "audio_and_extension"),
    npm("local_server_check", "apps/mac/local-server", ["run", "check"], "local_access_and_secrets"),
    npm("local_server_tests", "apps/mac/local-server", ["test"], "local_access_and_secrets"),
    npm("native_host_check", "apps/mac/native-host", ["run", "check"], "command_and_origin"),
    npm("native_host_tests", "apps/mac/native-host", ["test"], "command_and_origin"),
    component("mimi_app_tests", "apps/mac/MimiApp", tools.swift, ["test"], "update_integrity"),
    component("security_gate_tests", "", tools.node, ["--test", "scripts/test/mimi-security-gate.test.cjs"], "gate_fail_closed"),
    component("chrome_package", "", tools.node, [
      "scripts/package-chrome-extension.cjs",
      `--out=${path.join(workRoot, "chrome-package")}`,
    ], "package_integrity"),
    component("mimi_app_package", "", tools.node, [
      "scripts/package-mimi-app.cjs",
      `--node=${tools.node}`,
      `--dist=${path.join(workRoot, "app-package")}`,
    ], "package_integrity"),
    component("diff_whitespace", "", tools.git, ["diff", "--check"], "scoped_diff"),
  ];
}
function trustedTooling() {
  const node = fs.realpathSync(process.execPath);
  const npmCli = path.resolve(path.dirname(node), "../lib/node_modules/npm/bin/npm-cli.js");
  const tools = { node, npmCli, swift: "/usr/bin/swift", git: "/usr/bin/git" };
  for (const [name, filePath] of Object.entries(tools)) {
    if (!path.isAbsolute(filePath) || !fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      throw new Error(`missing_trusted_tool:${name}`);
    }
  }
  return tools;
}
async function runSecurityGate(options = {}) {
  const repoRoot = path.resolve(options.repoRoot || path.join(__dirname, "..", ".."));
  const outputDir = path.resolve(options.outputDir);
  const workRoot = fs.mkdtempSync(path.join(os.tmpdir(), "mimi-security-gate-"));
  prepareOutputDirectory(outputDir);

  const staticEvidence = inspectReleaseSurface(repoRoot);
  const runCommand = options.runCommand || executeCommand;
  const commandEvidence = [];
  let localArtifacts = { evidenceMode: "injected_test", tamperRejected: true };
  let packageTamperEvidence = passEvidence("packaged_artifact_tamper_negative", "package_tamper");
  try {
    for (const check of buildCommandPlan(repoRoot, workRoot)) {
      const result = await runCommand(check);
      commandEvidence.push({
        id: check.id,
        category: check.category,
        status: result.status === 0 ? "PASS" : "FAIL",
        severity: result.status === 0 ? null : "high",
      });
    }
    if (!options.runCommand) {
      const packagesPassed = commandEvidence
        .filter((entry) => ["chrome_package", "mimi_app_package"].includes(entry.id))
        .every((entry) => entry.status === "PASS");
      if (packagesPassed) {
        try {
          localArtifacts = collectLocalArtifactEvidence(workRoot);
          if (!localArtifacts.tamperRejected) packageTamperEvidence = failedEvidence("packaged_artifact_tamper_negative", "package_tamper", "high");
        } catch {
          localArtifacts = { available: false, tamperRejected: false };
          packageTamperEvidence = failedEvidence("packaged_artifact_tamper_negative", "package_tamper", "high");
        }
      } else {
        localArtifacts = { available: false, tamperRejected: false };
        packageTamperEvidence = failedEvidence("packaged_artifact_tamper_negative", "package_tamper", "high");
      }
    }
  } finally {
    fs.rmSync(workRoot, { recursive: true, force: true });
  }

  const candidate = (options.readCandidateIdentity || readCandidateIdentity)(repoRoot);
  const originEvidence = candidate.canonicalOriginMatch
    ? passEvidence("canonical_origin_match", "loopback_origin")
    : failedEvidence("canonical_origin_match", "loopback_origin", "high");
  const evidence = [...staticEvidence, ...commandEvidence, packageTamperEvidence, originEvidence];
  const unresolved = countUnresolved(evidence);
  const report = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    gate: unresolved.critical + unresolved.high + unresolved.medium === 0 ? "PASS" : "NO_GO",
    scope: "MIMI-REL-004 synthetic/local pre-first-invitation Security Gate",
    candidate,
    localArtifacts,
    unresolved,
    evidence,
    threatModel: "docs/alpha/mimi-security-gate-threat-model.md",
    humanOnly: [
      "production_signing_notarization",
      "mimi_notary_profile",
      "external_live_update_feed",
      "dashboard_and_tester_distribution",
    ],
  };
  const jsonPath = path.join(outputDir, REPORT_JSON);
  const markdownPath = path.join(outputDir, REPORT_MARKDOWN);
  fs.writeFileSync(jsonPath, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
  fs.writeFileSync(markdownPath, renderMarkdown(report), { mode: 0o600 });
  return { report, jsonPath, markdownPath };
}

function inspectReleaseSurface(repoRoot) {
  const checks = [
    inspectDependencies(repoRoot),
    inspectKeyBoundary(repoRoot),
    inspectAudioStopCoverage(repoRoot),
    inspectLoopbackAndOrigin(repoRoot),
    inspectDiagnostics(repoRoot),
    inspectCommandAndPathSafety(repoRoot),
    inspectPackageIntegrity(repoRoot),
    inspectUpdaterIntegrity(repoRoot),
    inspectReleaseSurfaceData(repoRoot),
  ];
  return checks.map((check) => ({
    id: check.id,
    category: check.category,
    status: check.problems.length ? "FAIL" : "PASS",
    severity: check.problems.length ? check.severity : null,
  }));
}

function inspectDependencies(repoRoot) {
  const problems = [];
  const reviewedDependencies = {
    "apps/mac/extension/package.json": {},
    "apps/mac/local-server/package.json": {
      ws: "8.21.1",
    },
    "apps/mac/native-host/package.json": {},
  };
  for (const [relative, allowlist] of Object.entries(reviewedDependencies)) {
    const manifest = readJson(repoRoot, relative);
    const dependencies = manifest.dependencies || {};
    for (const [name, version] of Object.entries(dependencies)) {
      if (!Object.hasOwn(allowlist, name)) {
        problems.push(`${relative}:runtime_dependency_not_allowlisted:${name}`);
      } else if (version !== allowlist[name]) {
        problems.push(`${relative}:runtime_dependency_not_exact:${name}`);
      }
    }
    for (const name of Object.keys(allowlist)) {
      if (!Object.hasOwn(dependencies, name)) problems.push(`${relative}:runtime_dependency_missing:${name}`);
    }
    if (Object.keys(manifest.optionalDependencies || {}).length) problems.push(`${relative}:optional_dependencies`);
  }

  const lockRelative = "apps/mac/local-server/package-lock.json";
  const lock = readJson(repoRoot, lockRelative);
  const expectedWs = {
    version: "8.21.1",
    resolved: "https://registry.npmjs.org/ws/-/ws-8.21.1.tgz",
    integrity: "sha512-+0NTnW77fFN/DjQi6k/Sq/Yvk4Sgajw7urW8V+asjXnRgDs9gyGkdb7EzgfhA4goXsRIZKE28fzIXBHEzhuiWw==",
  };
  if (lock.lockfileVersion !== 3) problems.push(`${lockRelative}:lockfile_version`);
  const packages = lock.packages || {};
  const expectedPackageKeys = new Set(["", "node_modules/ws"]);
  for (const packageKey of Object.keys(packages)) {
    if (!expectedPackageKeys.has(packageKey)) problems.push(`${lockRelative}:unexpected_package:${packageKey}`);
  }
  for (const packageKey of expectedPackageKeys) {
    if (!Object.hasOwn(packages, packageKey)) problems.push(`${lockRelative}:missing_package:${packageKey || "root"}`);
  }
  const rootDependencies = packages[""]?.dependencies || {};
  if (rootDependencies.ws !== expectedWs.version) {
    problems.push(`${lockRelative}:root_dependency_mismatch:ws`);
  }
  for (const name of Object.keys(rootDependencies)) {
    if (name !== "ws") problems.push(`${lockRelative}:root_dependency_not_allowlisted:${name}`);
  }
  const lockedWs = packages["node_modules/ws"] || {};
  if (lockedWs.version !== expectedWs.version) problems.push(`${lockRelative}:locked_version_mismatch:ws`);
  if (lockedWs.resolved !== expectedWs.resolved) problems.push(`${lockRelative}:resolved_source_mismatch:ws`);
  if (lockedWs.integrity !== expectedWs.integrity) problems.push(`${lockRelative}:integrity_mismatch:ws`);

  const swift = readText(repoRoot, "apps/mac/MimiApp/Package.swift");
  if (swift.includes(".package(")) problems.push("MimiApp:external_package");
  const runtimes = readJson(repoRoot, "scripts/mimi-node-runtime.json");
  for (const runtime of runtimes.runtimes || []) {
    if (!/^https:\/\/nodejs\.org\/dist\//.test(runtime.url)) problems.push("node_runtime:wrong_source");
    if (!/^[a-f0-9]{64}$/.test(runtime.sha256 || "")) problems.push("node_runtime:missing_sha256");
  }
  return result("production_dependencies", "dependency_integrity", "high", problems);
}

function inspectKeyBoundary(repoRoot) {
  const extension = joinTexts(repoRoot, [
    "apps/mac/extension/src/service-worker.js",
    "apps/mac/extension/src/offscreen.js",
    "apps/mac/extension/src/popup.js",
  ]);
  const secrets = readText(repoRoot, "apps/mac/local-server/src/secrets.js");
  const tests = readText(repoRoot, "apps/mac/local-server/test/mac.test.js");
  return result("keychain_local_server_boundary", "secret", "critical", requireEvidence([
    [!extension.includes("GEMINI_API_KEY"), "extension_references_api_key"],
    [secrets.includes("find-generic-password"), "missing_keychain_read"],
    [secrets.includes("--save-api-key-stdin"), "missing_keychain_stdin_write"],
    [tests.includes("returns non-secret status"), "missing_non_secret_status_test"],
  ]));
}

function inspectAudioStopCoverage(repoRoot) {
  const extensionTests = joinTexts(repoRoot, [
    "apps/mac/extension/test/offscreen-playback.test.js",
    "apps/mac/extension/test/service-worker-start-mode.test.js",
  ]);
  const server = readText(repoRoot, "apps/mac/local-server/src/server.js");
  const tests = readText(repoRoot, "apps/mac/local-server/test/mac.test.js");
  return result("start_stop_error_quota_safety", "audio", "critical", requireEvidence([
    [server.includes("if (!session.started) return;"), "audio_before_start_not_blocked"],
    [server.includes('stopSession(session, "monthly_limit_reached")'), "safety_limit_not_stopping"],
    [server.includes("stopSession(session, error)"), "errors_not_stopping"],
    [extensionTests.includes("terminal idle reason"), "quota_idle_cleanup_test_missing"],
    [extensionTests.includes("cleans up capture resources when the server reports an error"), "error_cleanup_test_missing"],
    [extensionTests.includes("Stop leaves native-managed server running"), "explicit_stop_test_missing"],
    [tests.includes("Gemini quota and auth errors are classified as stop reasons"), "quota_classification_test_missing"],
  ]));
}

function inspectLoopbackAndOrigin(repoRoot) {
  const server = readText(repoRoot, "apps/mac/local-server/src/server.js");
  const policy = readText(repoRoot, "apps/mac/local-server/src/originPolicy.js");
  const tests = readText(repoRoot, "apps/mac/local-server/test/mac.test.js");
  return result("loopback_and_canonical_origin", "local_access", "high", requireEvidence([
    [server.includes('server.listen(PORT, "127.0.0.1"'), "server_not_loopback_bound"],
    [policy.includes('normalized.startsWith("chrome-extension://")'), "non_extension_origin_not_blocked"],
    [policy.includes("normalized === allowedExtensionOrigin"), "origin_not_exact"],
    [tests.includes("local websocket rejects arbitrary browser origins"), "origin_runtime_test_missing"],
  ]));
}

function inspectDiagnostics(repoRoot) {
  const server = readText(repoRoot, "apps/mac/local-server/src/server.js");
  const tests = readText(repoRoot, "apps/mac/local-server/test/mac.test.js");
  return result("default_off_audio_and_redacted_debug", "audio_and_secret", "high", requireEvidence([
    [server.includes('readBooleanEnv("JP_DUB_DIAGNOSTICS", false)'), "diagnostics_not_default_off"],
    [server.includes('readBooleanEnv("JP_DUB_CAPTURE_FIRST_INPUT_WAV", DIAGNOSTICS_ENABLED)'), "input_wav_not_gated"],
    [server.includes('readBooleanEnv("JP_DUB_CAPTURE_FIRST_OUTPUT_WAV", DIAGNOSTICS_ENABLED)'), "output_wav_not_gated"],
    [tests.includes("raw WAV capture stays off until diagnostics explicitly opt in"), "default_off_test_missing"],
    [tests.includes("debug collection redacts secrets from status logs and environment"), "debug_redaction_test_missing"],
  ]));
}

function inspectCommandAndPathSafety(repoRoot) {
  const relevant = joinTexts(repoRoot, [
    "apps/mac/local-server/src/secrets.js",
    "apps/mac/local-server/scripts/start-detached.js",
    "apps/mac/native-host/src/serverControl.js",
    "scripts/package-chrome-extension.cjs",
    "scripts/package-mimi-app.cjs",
  ]);
  const updateTests = readText(repoRoot, "apps/mac/MimiApp/Tests/MimiAppCoreTests/AppUpdaterTests.swift");
  return result("command_and_path_injection", "command_and_path", "high", requireEvidence([
    [!/(?:exec|spawn)(?:Sync)?\([^\n]+\{[^}]*shell\s*:\s*true/s.test(relevant), "shell_execution_enabled"],
    [relevant.includes("execFileSync"), "argument_array_execution_missing"],
    [readText(repoRoot, "apps/mac/local-server/test/mac.test.js").includes("metacharacters as inert argv"), "argv_injection_test_missing"],
    [updateTests.includes("updateRejectsTraversalAbsoluteAndSymlinkArtifactPaths"), "updater_path_negative_test_missing"],
  ]));
}

function inspectReleaseSurfaceData(repoRoot) {
  const roots = [
    "apps/mac/extension/manifest.json",
    "apps/mac/extension/_locales",
    "apps/mac/extension/src",
    "apps/mac/local-server/package.json",
    "apps/mac/local-server/scripts",
    "apps/mac/local-server/src",
    "apps/mac/native-host/bin",
    "apps/mac/native-host/package.json",
    "apps/mac/native-host/scripts",
    "apps/mac/native-host/src",
    "apps/mac/MimiApp/Package.swift",
    "apps/mac/MimiApp/Sources",
    "scripts/mimi-node-runtime.json",
    "scripts/package-chrome-extension.cjs",
    "scripts/package-mimi-app.cjs",
  ];
  const secretPatterns = [
    /AIza[0-9A-Za-z_-]{20,}/,
    /gh[oprs]_[A-Za-z0-9_]{20,}/,
    /sk-[A-Za-z0-9_-]{20,}/,
    /BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY/,
    /Bearer\s+[A-Za-z0-9._~+/=-]{20,}/i,
    /\/Users\/[^\s"']+/,
  ];
  const audioExtensions = new Set([".aac", ".m4a", ".mp3", ".pcm", ".wav"]);
  const problems = [];
  for (const filePath of collectFiles(repoRoot, roots)) {
    const extension = path.extname(filePath).toLowerCase();
    if (audioExtensions.has(extension)) problems.push(`raw_audio:${path.basename(filePath)}`);
    if (![".cjs", ".html", ".js", ".json", ".swift"].includes(extension) && path.basename(filePath) !== "Package.swift") continue;
    const text = fs.readFileSync(filePath, "utf8");
    if (secretPatterns.some((pattern) => pattern.test(text))) problems.push(`secret_or_private_data:${path.basename(filePath)}`);
  }
  return result("release_surface_secret_private_data_scan", "secret_and_private_data", "critical", problems);
}

function inspectPackageIntegrity(repoRoot) {
  const chrome = readText(repoRoot, "scripts/package-chrome-extension.cjs");
  const app = readText(repoRoot, "scripts/package-mimi-app.cjs");
  return result("release_package_integrity", "package_tamper", "high", requireEvidence([
    [chrome.includes("assertNoForbiddenPackageFiles"), "chrome_forbidden_file_scan_missing"],
    [chrome.includes("assertNoSecretLikeText"), "chrome_secret_scan_missing"],
    [app.includes("findCopiedEnvFiles"), "app_env_exclusion_missing"],
    [app.includes("bundle-smoke-check"), "app_bundle_smoke_missing"],
  ]));
}

function inspectUpdaterIntegrity(repoRoot) {
  const updater = readText(repoRoot, "apps/mac/MimiApp/Sources/MimiAppCore/AppUpdater.swift");
  const tests = readText(repoRoot, "apps/mac/MimiApp/Tests/MimiAppCoreTests/AppUpdaterTests.swift");
  return result("updater_source_signature_and_rollback", "update", "critical", requireEvidence([
    [updater.includes("manifest.source == policy.expectedSource"), "source_check_missing"],
    [updater.includes("isValidSignature"), "signature_check_missing"],
    [updater.includes("checksumMismatch"), "checksum_check_missing"],
    [tests.includes("updateRejectsWrongSource"), "wrong_source_test_missing"],
    [tests.includes("updateRejectsInvalidSignature"), "invalid_signature_test_missing"],
    [tests.includes("corruptedArtifactLeavesCurrentVersionUntouched"), "tamper_test_missing"],
    [tests.includes("interruptedUpdateRecoversOriginalVersionDeterministically"), "rollback_test_missing"],
  ]));
}

function makeIntegrityManifest(root, relativePaths) {
  return relativePaths.map((relativePath) => ({
    path: relativePath,
    sha256: sha256(readFile(root, relativePath)),
  }));
}

function verifyIntegrityManifest(root, manifest) {
  return manifest.filter((entry) => {
    try {
      return sha256(readFile(root, entry.path)) !== entry.sha256;
    } catch {
      return true;
    }
  }).map((entry) => entry.path);
}

function readFile(root, relativePath) {
  if (root && root.files) {
    if (!root.files[relativePath]) throw new Error("missing_file");
    return root.files[relativePath];
  }
  return fs.readFileSync(path.join(root, relativePath));
}

function executeCommand(check) {
  return spawnSync(check.command, check.args, {
    cwd: check.cwd,
    encoding: "utf8",
    env: sanitizedEnvironment(check.workRoot),
    shell: false,
    timeout: 180000,
    maxBuffer: 2 * 1024 * 1024,
  });
}

function sanitizedEnvironment(workRoot) {
  const env = { ...process.env };
  for (const name of Object.keys(env)) {
    if (/key|token|secret|credential|authorization|password/i.test(name)) delete env[name];
  }
  const home = path.join(workRoot, "home");
  const temporary = path.join(workRoot, "tmp");
  const cache = path.join(workRoot, "cache");
  fs.mkdirSync(home, { recursive: true });
  fs.mkdirSync(temporary, { recursive: true });
  fs.mkdirSync(cache, { recursive: true });
  env.HOME = home;
  env.TMPDIR = temporary;
  env.XDG_CACHE_HOME = cache;
  env.CLANG_MODULE_CACHE_PATH = env.CLANG_MODULE_CACHE_PATH || "/private/tmp/mimi-security-clang-cache";
  env.SWIFTPM_MODULECACHE_OVERRIDE = env.SWIFTPM_MODULECACHE_OVERRIDE || "/private/tmp/mimi-security-swift-cache";
  env.PATH = `${path.dirname(fs.realpathSync(process.execPath))}:/usr/bin:/bin`;
  return env;
}

function hashNamedFiles(root, relativePaths) {
  const hasher = crypto.createHash("sha256");
  for (const relative of [...relativePaths].sort()) {
    hasher.update(`${Buffer.byteLength(relative)}:${relative}:`);
    hasher.update(fs.readFileSync(path.join(root, relative)));
  }
  return hasher.digest("hex");
}

function prepareOutputDirectory(outputDir) {
  if (!outputDir) throw new Error("missing_output_dir");
  fs.mkdirSync(outputDir, { recursive: true });
  const stat = fs.lstatSync(outputDir);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("unsafe_output_dir");
}

function readCandidateIdentity(repoRoot) {
  const manifest = readJson(repoRoot, "apps/mac/extension/manifest.json");
  const origin = resolveExtensionOriginDetails({
    env: {},
    manifestPath: path.join(repoRoot, "apps/mac/extension/manifest.json"),
  });
  const nativeHost = buildHostManifest({
    hostPath: "/Applications/Mimi.app/Contents/MacOS/jp-dub-native-host",
    extensionOrigin: origin.origin,
  });
  const localServerOrigin = resolveExtensionOriginDetails({
    env: {},
    manifestPath: path.join(repoRoot, "apps/mac/extension/manifest.json"),
  }).origin;
  const evidencePaths = [
    "apps/mac/extension/manifest.json",
    "apps/mac/extension/src/offscreen.js",
    "apps/mac/extension/src/service-worker.js",
    "apps/mac/extension/test/offscreen-playback.test.js",
    "apps/mac/extension/test/service-worker-start-mode.test.js",
    "apps/mac/local-server/scripts/collect-debug.js",
    "apps/mac/local-server/src/server.js",
    "apps/mac/local-server/src/secrets.js",
    "apps/mac/local-server/test/mac.test.js",
    "apps/mac/native-host/src/serverControl.js",
    "apps/mac/native-host/test/native-host.test.js",
    "apps/mac/MimiApp/Sources/MimiAppCore/AppUpdater.swift",
    "apps/mac/MimiApp/Tests/MimiAppCoreTests/AppUpdaterTests.swift",
    "scripts/lib/mimiSecurityGate.cjs",
    "scripts/lib/mimiPackageIntegrity.cjs",
    "scripts/run-mimi-security-gate.cjs",
    "scripts/test/mimi-security-gate.test.cjs",
  ];
  return {
    marketingVersion: manifest.version,
    extensionId: origin.extensionId,
    canonicalOriginMatch: origin.source === "manifest_key"
      && origin.origin === `chrome-extension://${origin.extensionId}`
      && localServerOrigin === origin.origin
      && nativeHost.allowed_origins[0] === `${origin.origin}/`,
    sourceEvidenceSHA256: hashNamedFiles(repoRoot, evidencePaths),
  };
}

function countUnresolved(evidence) {
  const unresolved = { critical: 0, high: 0, medium: 0 };
  for (const entry of evidence) {
    if (entry.status === "FAIL" && entry.severity in unresolved) unresolved[entry.severity] += 1;
  }
  return unresolved;
}

function renderMarkdown(report) {
  const rows = report.evidence.map((entry) => `| ${entry.id} | ${entry.category} | ${entry.status} |`).join("\n");
  return `# Mimi Security Gate preflight\n\nGate: **${report.gate}**\n\n` +
    `Unresolved: Critical ${report.unresolved.critical}, High ${report.unresolved.high}, Medium ${report.unresolved.medium}.\n\n` +
    `| Evidence | Category | Result |\n| --- | --- | --- |\n${rows}\n\n` +
    `Human-only / not executed: ${report.humanOnly.join(", ")}.\n`;
}

function result(id, category, severity, problems) {
  return { id, category, severity, problems };
}

function passEvidence(id, category) {
  return { id, category, status: "PASS", severity: null };
}

function failedEvidence(id, category, severity) {
  return { id, category, status: "FAIL", severity };
}

function requireEvidence(entries) {
  return entries.filter(([passes]) => !passes).map(([, problem]) => problem);
}

function readText(repoRoot, relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function readJson(repoRoot, relativePath) {
  return JSON.parse(readText(repoRoot, relativePath));
}

function joinTexts(repoRoot, relativePaths) {
  return relativePaths.map((relative) => readText(repoRoot, relative)).join("\n");
}

function collectFiles(repoRoot, roots) {
  const files = [];
  for (const relative of roots) {
    const target = path.join(repoRoot, relative);
    const stat = fs.statSync(target);
    if (stat.isFile()) {
      files.push(target);
      continue;
    }
    for (const entry of fs.readdirSync(target, { withFileTypes: true })) {
      const childRelative = path.join(relative, entry.name);
      if (entry.isDirectory()) files.push(...collectFiles(repoRoot, [childRelative]));
      if (entry.isFile()) files.push(path.join(repoRoot, childRelative));
    }
  }
  return files;
}

function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

module.exports = {
  buildCommandPlan,
  inspectDependencies,
  makeIntegrityManifest,
  runSecurityGate,
  verifyIntegrityManifest,
};
