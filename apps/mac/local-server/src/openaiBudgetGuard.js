const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

// OpenAI's published realtime translation rate is an estimate of API spend,
// not a billing receipt. The guard deliberately stops below the $1 boundary.
const OPENAI_AUDIO_USD_PER_MINUTE = 0.034;
const OPENAI_LIFETIME_LIMIT_USD = 1;
const OPENAI_SAFE_CAP_SECONDS = 28 * 60;
const OPENAI_SAFE_CAP_USD = roundUsd((OPENAI_SAFE_CAP_SECONDS / 60) * OPENAI_AUDIO_USD_PER_MINUTE);
const STORAGE_VERSION = 1;
const STORAGE_PROVIDER = "openai";
const STORAGE_SCOPE = "mimi-lifetime";

class OpenAIBudgetGuard {
  constructor(options = {}) {
    if (typeof options === "string") options = { storagePath: options };
    if (!options || typeof options !== "object") options = {};

    this.limitSeconds = normalizeLimitSeconds(options.limitSeconds);
    this.storagePath = options.storagePath === undefined
      ? defaultStoragePath(options.env || process.env)
      : options.storagePath;
    this.usedSeconds = 0;
    this.dirty = false;
    this.persistenceAvailable = false;
    this.persistenceReason = "storage_unavailable";
    this.load();
  }

  canUse(additionalSeconds = 0) {
    const seconds = normalizeSeconds(additionalSeconds);
    if (seconds === null || !this.persistenceAvailable) return false;
    return this.usedSeconds + seconds <= this.limitSeconds;
  }

  // Reserve and persist synchronously before the caller sends audio. A failed
  // write blocks all future use, even when the previous on-disk value is lower.
  reserve(seconds = 0) {
    const normalized = normalizeSeconds(seconds);
    if (normalized === null || !this.canUse(normalized)) return false;
    if (normalized === 0) return true;

    this.usedSeconds += normalized;
    this.dirty = true;
    if (this.save(true)) return true;

    // Persistence is now untrusted. Keep the in-memory view conservative too.
    this.usedSeconds = this.limitSeconds;
    this.dirty = false;
    return false;
  }

  record(seconds = 0) {
    return this.reserve(seconds);
  }

  add(seconds = 0) {
    return this.reserve(seconds);
  }

  addSeconds(seconds = 0) {
    return this.reserve(seconds);
  }

  snapshot() {
    const available = this.persistenceAvailable;
    const usedSeconds = Math.min(this.limitSeconds, Math.max(0, Math.ceil(this.usedSeconds)));
    const remainingSeconds = available ? Math.max(0, this.limitSeconds - usedSeconds) : 0;
    const usedUsd = roundUsd((usedSeconds / 60) * OPENAI_AUDIO_USD_PER_MINUTE);
    const remainingUsd = available
      ? roundUsd((remainingSeconds / 60) * OPENAI_AUDIO_USD_PER_MINUTE)
      : 0;

    return {
      provider: STORAGE_PROVIDER,
      period: "lifetime",
      scope: STORAGE_SCOPE,
      limitSeconds: this.limitSeconds,
      usedSeconds,
      remainingSeconds,
      limitUsd: roundUsd((this.limitSeconds / 60) * OPENAI_AUDIO_USD_PER_MINUTE),
      usedUsd,
      remainingUsd,
      measuredLabel: "measured",
      estimatedLabel: "estimated",
      // Explicit labels prevent estimated USD from being mistaken for a
      // provider invoice while keeping measured audio seconds visible.
      measured: {
        label: "measured",
        usedSeconds,
        remainingSeconds,
      },
      estimated: {
        label: "estimated",
        usedUsd,
        remainingUsd,
        rateUsdPerAudioMinute: OPENAI_AUDIO_USD_PER_MINUTE,
      },
      usage: {
        label: "measured",
        usedSeconds,
        remainingSeconds,
      },
      cost: {
        label: "estimated",
        totalUsd: usedUsd,
        remainingUsd,
        usdPerAudioMinute: OPENAI_AUDIO_USD_PER_MINUTE,
      },
      persistence: {
        available,
        status: available ? "ready" : "blocked",
        reason: available ? null : this.persistenceReason,
      },
    };
  }

  flush() {
    return this.save(true);
  }

  load() {
    if (!this.storagePath) {
      this.failClosed("storage_unavailable");
      return;
    }

    let storagePath;
    try {
      storagePath = path.resolve(this.storagePath);
    } catch {
      this.failClosed("storage_unavailable");
      return;
    }
    this.storagePath = storagePath;
    let raw;
    try {
      raw = fs.readFileSync(storagePath, "utf8");
    } catch (error) {
      if (error && error.code === "ENOENT") {
        this.persistenceAvailable = true;
        this.persistenceReason = null;
        this.dirty = true;
        if (!this.save(true)) this.failClosed("storage_unavailable");
        return;
      }
      this.failClosed("storage_unavailable");
      return;
    }

    let data;
    try {
      data = JSON.parse(raw);
    } catch {
      this.failClosed("storage_corrupt");
      return;
    }

    if (!isValidState(data, this.limitSeconds)) {
      this.failClosed("storage_corrupt");
      return;
    }

    this.usedSeconds = data.usedSeconds;
    this.persistenceAvailable = true;
    this.persistenceReason = null;
    this.dirty = false;
  }

  save(force = false) {
    if (!this.persistenceAvailable || !this.storagePath) return false;
    if (!force && !this.dirty) return true;

    try {
      fs.mkdirSync(path.dirname(this.storagePath), { recursive: true });
      const temporaryPath = `${this.storagePath}.tmp-${process.pid}-${Date.now()}`;
      const descriptor = fs.openSync(temporaryPath, "wx", 0o600);
      try {
        fs.writeFileSync(descriptor, `${JSON.stringify(this.serializedState(), null, 2)}\n`, "utf8");
        fs.fsyncSync(descriptor);
      } finally {
        fs.closeSync(descriptor);
      }
      fs.renameSync(temporaryPath, this.storagePath);
      this.dirty = false;
      return true;
    } catch {
      this.failClosed("storage_unavailable");
      return false;
    }
  }

  serializedState() {
    return {
      version: STORAGE_VERSION,
      provider: STORAGE_PROVIDER,
      scope: STORAGE_SCOPE,
      limitSeconds: this.limitSeconds,
      usedSeconds: Math.min(this.limitSeconds, Math.max(0, this.usedSeconds)),
      updatedAt: new Date().toISOString(),
    };
  }

  failClosed(reason) {
    this.persistenceAvailable = false;
    this.persistenceReason = reason;
  }
}

function defaultStoragePath() {
  const bundledSegment = `${path.sep}Contents${path.sep}Resources${path.sep}local-server${path.sep}src`;
  if (__dirname.includes(bundledSegment)) {
    return path.join(
      os.homedir(),
      "Library",
      "Application Support",
      "Mimi",
      "tmp",
      "mimi-openai-lifetime-usage.json",
    );
  }
  return path.resolve(__dirname, "..", "..", "..", "..", "tmp", "mimi-openai-lifetime-usage.json");
}

function normalizeLimitSeconds(value) {
  if (!Number.isFinite(value) || value <= 0) return OPENAI_SAFE_CAP_SECONDS;
  return Math.min(OPENAI_SAFE_CAP_SECONDS, Math.floor(value));
}

function normalizeSeconds(value) {
  if (!Number.isFinite(value) || value < 0) return null;
  return Number(value);
}

function isValidState(data, limitSeconds) {
  return Boolean(
    data
      && typeof data === "object"
      && data.version === STORAGE_VERSION
      && data.provider === STORAGE_PROVIDER
      && data.scope === STORAGE_SCOPE
      && data.limitSeconds === limitSeconds
      && Number.isFinite(data.usedSeconds)
      && data.usedSeconds >= 0
      && data.usedSeconds <= limitSeconds,
  );
}

function roundUsd(value) {
  return Math.round(value * 1_000_000) / 1_000_000;
}

module.exports = {
  OPENAI_AUDIO_USD_PER_MINUTE,
  OPENAI_LIFETIME_LIMIT_USD,
  OPENAI_SAFE_CAP_SECONDS,
  OPENAI_SAFE_CAP_USD,
  OpenAIBudgetGuard,
  defaultStoragePath,
};
