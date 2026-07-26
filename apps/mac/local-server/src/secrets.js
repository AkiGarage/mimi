const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const DEFAULT_KEYCHAIN_SERVICE = "Mimi Gemini API Key";
const DEFAULT_OPENAI_KEYCHAIN_SERVICE = "Mimi OpenAI API Key";
const DEFAULT_KEYCHAIN_ACCOUNT = "default";
const SECURITY_BIN = "/usr/bin/security";

function getGeminiApiKey(options = {}) {
  return resolveGeminiApiKey(options).value;
}

function hasGeminiApiKey(options = {}) {
  return Boolean(getGeminiApiKey(options));
}

function geminiApiKeyStatus(options = {}) {
  const resolved = resolveGeminiApiKey(options);
  return {
    configured: Boolean(resolved.value),
    canReplace: Boolean(keychainHelperPath(options.env || process.env)),
    source: resolved.source,
    keychainEnabled: resolved.keychainEnabled,
    keychainService: resolved.keychainService,
    keychainAccount: resolved.keychainAccount,
  };
}

function makeGeminiApiKeyStatusCache(options = {}) {
  return makeStatusCache(geminiApiKeyStatus, options);
}

function makeStatusCache(statusReader, options = {}) {
  const ttlMs = Math.max(0, Number(options.ttlMs ?? 5000));
  const statusOptions = options.statusOptions || {};
  let cached = null;
  return {
    get(readOptions = {}) {
      const now = Number(readOptions.now ?? Date.now());
      if (cached && now - cached.atMs < ttlMs) return cached.status;
      const { now: _now, ...readStatusOptions } = readOptions;
      const status = statusReader({ ...statusOptions, ...readStatusOptions });
      cached = { atMs: now, status };
      return status;
    },
    set(status, now = Date.now()) {
      cached = { atMs: Number(now), status };
    },
    clear() {
      cached = null;
    },
  };
}

function saveGeminiApiKey(value, options = {}) {
  const env = options.env || process.env;
  const keychainService = options.keychainService || env.JP_DUB_KEYCHAIN_SERVICE || DEFAULT_KEYCHAIN_SERVICE;
  const keychainAccount = options.keychainAccount || env.JP_DUB_KEYCHAIN_ACCOUNT || DEFAULT_KEYCHAIN_ACCOUNT;
  const key = normalizeSecret(value);
  if (!key) {
    throw new Error("empty_api_key");
  }
  if (!isKeychainEnabled(env, options.platform || process.platform)) {
    throw new Error("keychain_unavailable");
  }
  writeKeychainPassword({
    account: keychainAccount,
    env,
    execFileSync: options.execFileSync,
    helperPath: options.helperPath,
    password: key,
    service: keychainService,
  });
  return geminiApiKeyStatus(options);
}

function getOpenAIApiKey(options = {}) {
  return resolveOpenAIApiKey(options).value;
}

function openAIApiKeyStatus(options = {}) {
  const resolved = resolveOpenAIApiKey(options);
  return {
    configured: Boolean(resolved.value),
    canReplace: Boolean(options.helperPath || openAIKeychainHelperPath()),
    source: resolved.source,
    keychainEnabled: resolved.keychainEnabled,
    keychainService: resolved.keychainService,
    keychainAccount: resolved.keychainAccount,
  };
}

function makeOpenAIApiKeyStatusCache(options = {}) {
  return makeStatusCache(openAIApiKeyStatus, options);
}

function saveOpenAIApiKey(value, options = {}) {
  const env = options.env || process.env;
  const keychainService = options.keychainService || DEFAULT_OPENAI_KEYCHAIN_SERVICE;
  const keychainAccount = options.keychainAccount || DEFAULT_KEYCHAIN_ACCOUNT;
  const key = normalizeSecret(value);
  if (!key) throw new Error("empty_api_key");
  if (!isKeychainEnabled(env, options.platform || process.platform)) {
    throw new Error("keychain_unavailable");
  }
  writeKeychainPassword({
    account: keychainAccount,
    env,
    execFileSync: options.execFileSync,
    helperPath: options.helperPath || openAIKeychainHelperPath(),
    password: key,
    service: keychainService,
  });
  return openAIApiKeyStatus(options);
}

function resolveOpenAIApiKey(options = {}) {
  const env = options.env || process.env;
  const keychainService = options.keychainService || DEFAULT_OPENAI_KEYCHAIN_SERVICE;
  const keychainAccount = options.keychainAccount || DEFAULT_KEYCHAIN_ACCOUNT;
  const keychainEnabled = isKeychainEnabled(env, options.platform || process.platform);
  const base = { keychainEnabled, keychainService, keychainAccount };
  if (!keychainEnabled) return { ...base, value: "", source: "missing" };
  const keychainValue = readKeychainPassword({
    account: keychainAccount,
    execFileSync: options.execFileSync,
    service: keychainService,
  });
  return {
    ...base,
    value: keychainValue,
    source: keychainValue ? "keychain" : "missing",
  };
}

function resolveGeminiApiKey(options = {}) {
  const env = options.env || process.env;
  const keychainService = options.keychainService || env.JP_DUB_KEYCHAIN_SERVICE || DEFAULT_KEYCHAIN_SERVICE;
  const keychainAccount = options.keychainAccount || env.JP_DUB_KEYCHAIN_ACCOUNT || DEFAULT_KEYCHAIN_ACCOUNT;
  const envValue = normalizeSecret(env.GEMINI_API_KEY);
  const keychainEnabled = isKeychainEnabled(env, options.platform || process.platform);
  const base = {
    keychainEnabled,
    keychainService,
    keychainAccount,
  };

  if (envValue) {
    return { ...base, value: envValue, source: "env" };
  }

  if (!keychainEnabled) {
    return { ...base, value: "", source: "missing" };
  }

  const keychainValue = readKeychainPassword({
    account: keychainAccount,
    execFileSync: options.execFileSync,
    service: keychainService,
  });
  return {
    ...base,
    value: keychainValue,
    source: keychainValue ? "keychain" : "missing",
  };
}

function readKeychainPassword(options = {}) {
  const run = options.execFileSync || execFileSync;
  try {
    const output = run(SECURITY_BIN, [
      "find-generic-password",
      "-s",
      options.service || DEFAULT_KEYCHAIN_SERVICE,
      "-a",
      options.account || DEFAULT_KEYCHAIN_ACCOUNT,
      "-w",
    ], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return normalizeSecret(output);
  } catch {
    return "";
  }
}

function writeKeychainPassword(options = {}) {
  const run = options.execFileSync || execFileSync;
  const helperPath = options.helperPath !== undefined
    ? options.helperPath
    : keychainHelperPath(options.env || process.env);
  if (!helperPath) {
    throw new Error("keychain_helper_unavailable");
  }
  try {
    run(helperPath, [
      "--save-api-key-stdin",
      options.service || DEFAULT_KEYCHAIN_SERVICE,
      options.account || DEFAULT_KEYCHAIN_ACCOUNT,
    ], {
      encoding: "utf8",
      input: options.password,
      stdio: ["pipe", "ignore", "ignore"],
    });
  } catch {
    throw new Error("keychain_write_failed");
  }
}

function keychainHelperPath(env = process.env) {
  if (env.JP_DUB_KEYCHAIN_HELPER) return path.resolve(env.JP_DUB_KEYCHAIN_HELPER);
  const packaged = path.resolve(__dirname, "..", "..", "..", "MacOS", "Mimi");
  return fs.existsSync(packaged) ? packaged : "";
}

function openAIKeychainHelperPath() {
  const packaged = path.resolve(__dirname, "..", "..", "..", "MacOS", "Mimi");
  return fs.existsSync(packaged) ? packaged : "";
}

function isKeychainEnabled(env, platform) {
  if (env.JP_DUB_USE_KEYCHAIN === "false" || env.JP_DUB_USE_KEYCHAIN === "0") return false;
  return platform === "darwin";
}

function normalizeSecret(value) {
  if (typeof value !== "string") return "";
  return value.replace(/[\r\n]+$/g, "").trim();
}

module.exports = {
  DEFAULT_KEYCHAIN_ACCOUNT,
  DEFAULT_KEYCHAIN_SERVICE,
  DEFAULT_OPENAI_KEYCHAIN_SERVICE,
  geminiApiKeyStatus,
  getGeminiApiKey,
  getOpenAIApiKey,
  hasGeminiApiKey,
  isKeychainEnabled,
  keychainHelperPath,
  makeGeminiApiKeyStatusCache,
  makeOpenAIApiKeyStatusCache,
  openAIKeychainHelperPath,
  openAIApiKeyStatus,
  readKeychainPassword,
  resolveGeminiApiKey,
  resolveOpenAIApiKey,
  saveGeminiApiKey,
  saveOpenAIApiKey,
  writeKeychainPassword,
};
