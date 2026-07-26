const fs = require("fs");
const http = require("http");
const path = require("path");
const { execFileSync } = require("child_process");
const { isMimiLocalServerProcess } = require("./start-detached");

const root = path.resolve(__dirname, "..", "..", "..", "..");
const pidFile = path.join(root, "tmp", "jp-dub-local-server.pid");
const port = Number(process.env.JP_DUB_PORT || 8787);
const STOP_TIMEOUT_MS = 4000;
const STOP_POLL_MS = 100;

if (require.main === module) {
  main().catch((error) => {
    console.error(`Failed to stop JP Dub local server: ${error.message}`);
    process.exit(1);
  });
}

async function main() {
  const pid = readPid();
  if (pid) {
    if (isSafePidForStop(pid)) {
      stopPid(pid);
      unlinkPidFile();
      await waitForStopped();
      return;
    }
    console.warn(`Ignoring stale JP Dub pid file for unrelated pid=${pid}`);
    unlinkPidFile();
  }

  const status = await fetchStatus().catch(() => null);
  if (!isJpDubServer(status)) {
    console.log("No JP Dub local server found.");
    return;
  }

  const listenerPid = findListenerPid();
  if (!listenerPid) {
    console.log(`JP Dub local server is running on port ${port}, but listener pid was not found.`);
    return;
  }
  stopPid(listenerPid);
  unlinkPidFile();
  await waitForStopped();
}

function stopPid(pid) {
  try {
    process.kill(pid, "SIGTERM");
    console.log(`Stopped JP Dub local server pid=${pid}`);
  } catch (error) {
    if (error.code === "ESRCH") {
      console.log(`JP Dub local server pid=${pid} was not running.`);
      return;
    }
    throw error;
  }
}

function readPid() {
  try {
    return Number(fs.readFileSync(pidFile, "utf8").trim());
  } catch {
    return 0;
  }
}

function unlinkPidFile() {
  try {
    fs.unlinkSync(pidFile);
  } catch {
    // Ignore missing pid file.
  }
}

function findListenerPid() {
  try {
    const value = execFileSync("lsof", ["-nP", "-tiTCP:" + port, "-sTCP:LISTEN"], { encoding: "utf8" }).trim();
    return Number(value.split(/\s+/)[0] || 0);
  } catch {
    return 0;
  }
}

function fetchStatus() {
  return new Promise((resolve, reject) => {
    const request = http.get(`http://127.0.0.1:${port}/status`, (response) => {
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
    request.setTimeout(900, () => {
      request.destroy(new Error("status_timeout"));
    });
  });
}

function isJpDubServer(status) {
  return status?.ok === true && status.service === "jp-dub-local-server";
}

async function waitForStopped(options = {}) {
  const readStatus = options.fetchStatus || fetchStatus;
  const wait = options.delay || delay;
  const timeoutMs = Number(options.timeoutMs ?? STOP_TIMEOUT_MS);
  const pollMs = Number(options.pollMs ?? STOP_POLL_MS);
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    const status = await readStatus().catch(() => null);
    if (!isJpDubServer(status)) return;
    await wait(pollMs);
  }
  throw new Error("local_server_stop_timeout");
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function isSafePidForStop(pid, options = {}) {
  return isMimiLocalServerProcess(pid, options);
}

module.exports = {
  findListenerPid,
  isJpDubServer,
  isSafePidForStop,
  main,
  readPid,
  waitForStopped,
};
