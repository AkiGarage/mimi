const http = require("http");
const { execFileSync } = require("child_process");
const { loadLocalEnv, localEnvDiagnostics } = require("../src/localEnv");
const { geminiApiKeyStatus } = require("../src/secrets");

loadLocalEnv();

const port = Number(process.env.JP_DUB_PORT || 8787);
const statusUrl = `http://127.0.0.1:${port}/status`;

main().catch((error) => {
  console.error(`FAIL doctor ${error.message}`);
  process.exit(1);
});

async function main() {
  const env = localEnvDiagnostics();
  const secret = geminiApiKeyStatus();
  print("env file", env.exists ? "found" : "not found");
  print("developer env fallback line", env.hasGeminiKeyLine ? "present" : "missing");
  print("Gemini API key configured", secret.configured ? `yes (${secret.source})` : "no");
  print("Keychain service", secret.keychainEnabled ? `${secret.keychainService} / ${secret.keychainAccount}` : "disabled or unavailable");
  print("JP_DUB_ALLOWED_EXTENSION_ORIGIN", process.env.JP_DUB_ALLOWED_EXTENSION_ORIGIN ? "present" : "missing");
  print("JP_DUB_TARGET_LANGUAGE", process.env.JP_DUB_TARGET_LANGUAGE || "(unset)");

  const listener = findListener(port);
  print(`port ${port}`, listener || "free");
  if (!listener) {
    console.log(`NEXT start server: npm start`);
    return;
  }

  const status = await fetchJson(statusUrl).catch((error) => ({ ok: false, error: error.message }));
  if (!status.ok || status.service !== "jp-dub-local-server") {
    console.log(`FAIL port ${port} is not Mimi. Current /status did not return Mimi JSON.`);
    console.log(`NEXT stop the process shown above, then run: npm start`);
    process.exit(1);
  }

  print("server", "Mimi is running");
  print("server mode", status.mode);
  print("real ready", status.realModeReady ? "yes" : "no");
  print("allowed extension origin", status.allowedExtensionOriginConfigured ? "configured" : "missing");
  print("active sessions", String(status.activeSessions));
  if (status.billing) {
    const usage = status.billing.displayUsage || status.billing.estimatedUsage || status.billing.usage || {};
    print("safety remaining seconds", String(status.billing.remainingSeconds || 0));
    print("advanced estimated tokens", `in ${usage.inputTokens || 0} / out ${usage.outputTokens || 0}`);
    print("advanced paid-tier estimate", `$${Number(status.billing.cost?.totalUsd || 0).toFixed(4)} / ¥${Math.round(status.billing.cost?.totalJpy || 0)}`);
  }
  if (status.lastSession) {
    print("last input bytes", String(status.lastSession.inputBytes || 0));
    print("last captured input bytes", String(status.lastSession.capturedInputBytes || 0));
    print("last output bytes", String(status.lastSession.outputBytes || 0));
    print("last output transcript", status.lastSession.outputTranscript || "(none)");
    print("last error", status.lastSession.lastError || "(none)");
  }
  console.log(`OPEN ${statusUrl}`);
}

function print(label, value) {
  console.log(`${label}: ${value}`);
}

function findListener(port) {
  try {
    return execFileSync("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN"], { encoding: "utf8" }).trim();
  } catch {
    return "";
  }
}

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const request = http.get(url, (response) => {
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
    request.setTimeout(3000, () => {
      request.destroy(new Error("status_timeout"));
    });
  });
}
