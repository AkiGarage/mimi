#!/usr/bin/env node
"use strict";

const path = require("node:path");
const { runSecurityGate } = require("./lib/mimiSecurityGate.cjs");

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const outputDir = options.outputDir || defaultOutputDir();
  const result = await runSecurityGate({
    repoRoot: path.resolve(__dirname, ".."),
    outputDir,
  });
  console.log(`${result.report.gate} mimi_security_gate_preflight`);
  console.log(`report=${path.relative(process.cwd(), result.markdownPath)}`);
  if (result.report.gate !== "PASS") process.exitCode = 1;
}

function parseArgs(args) {
  const options = {};
  for (const arg of args) {
    if (arg.startsWith("--output-dir=")) {
      options.outputDir = path.resolve(arg.slice("--output-dir=".length));
    } else {
      throw new Error(`unknown_argument:${arg}`);
    }
  }
  return options;
}

function defaultOutputDir() {
  const timestamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "").replace("T", "-");
  return path.resolve(
    __dirname,
    "..",
    "artifacts",
    "security-gates",
    `${timestamp}__codex__security-gate__mimi-rel-004`,
  );
}

main().catch((error) => {
  console.error(`FAIL mimi_security_gate_preflight ${error.message}`);
  process.exit(1);
});
