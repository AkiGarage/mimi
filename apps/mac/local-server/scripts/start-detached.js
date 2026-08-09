const fs = require("fs");
const path = require("path");
const { execFileSync, spawn } = require("child_process");

const root = path.resolve(__dirname, "..", "..", "..", "..");
const cwd = path.resolve(__dirname, "..");
const tmpDir = path.join(root, "tmp");
const logsDir = path.join(root, "logs");
const pidFile = path.join(tmpDir, "jp-dub-local-server.pid");
const logFile = path.join(logsDir, "jp-dub-local-server.log");
const restartExisting = process.env.JP_DUB_RESTART_EXISTING === "true";

if (require.main === module) {
  main();
}

function main() {
  fs.mkdirSync(tmpDir, { recursive: true });
  fs.mkdirSync(logsDir, { recursive: true });

  const existing = readPid();
  if (existing && isRunning(existing)) {
    if (restartExisting) {
      if (isMimiLocalServerProcess(existing)) {
        stopPid(existing);
      } else {
        console.warn(`Ignoring stale JP Dub pid file for unrelated pid=${existing}`);
      }
      unlinkPidFile();
    } else {
      console.log(`JP Dub local server already running pid=${existing}`);
      process.exit(0);
    }
  }

  const output = fs.openSync(logFile, "a");
  const child = spawn(process.execPath, ["src/server.js"], {
    cwd,
    detached: true,
    stdio: ["ignore", output, output],
    env: process.env,
  });

  child.unref();
  fs.writeFileSync(pidFile, `${child.pid}\n`);
  console.log(`JP Dub local server started pid=${child.pid}`);
  console.log(`log: ${logFile}`);
}

function readPid() {
  try {
    return Number(fs.readFileSync(pidFile, "utf8").trim());
  } catch {
    return 0;
  }
}

function isRunning(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function stopPid(pid) {
  try {
    process.kill(pid, "SIGTERM");
    console.log(`Stopped existing JP Dub local server pid=${pid}`);
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}

function isMimiLocalServerProcess(pid, options = {}) {
  const command = readProcessCommand(pid, options);
  const processCwd = readProcessCwd(pid, options);
  return isLikelyMimiLocalServerCommand(command)
    && Boolean(processCwd)
    && path.resolve(processCwd) === path.resolve(options.serverCwd || cwd);
}

function isLikelyMimiLocalServerCommand(command) {
  const text = String(command || "").replace(/\\/g, "/");
  return /(^|\s)\S*node(\s|$)/.test(text) && text.includes("src/server.js");
}

function readProcessCommand(pid, options = {}) {
  const runner = options.execFileSync || execFileSync;
  try {
    return runner("ps", ["-p", String(pid), "-o", "command="], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return "";
  }
}

function readProcessCwd(pid, options = {}) {
  const runner = options.execFileSync || execFileSync;
  try {
    const output = runner("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const pathLine = output.split(/\r?\n/).find((line) => line.startsWith("n"));
    return pathLine ? pathLine.slice(1) : "";
  } catch {
    return "";
  }
}

function unlinkPidFile() {
  try {
    fs.unlinkSync(pidFile);
  } catch {
    // Ignore missing pid file.
  }
}

module.exports = {
  isLikelyMimiLocalServerCommand,
  isMimiLocalServerProcess,
  readProcessCommand,
  readProcessCwd,
};
