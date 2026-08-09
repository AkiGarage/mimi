const fs = require("fs");
const path = require("path");
const {
  estimateAudioTokensFromSeconds,
  estimateLiveTranslateCost,
  maxUsage,
  readUsdJpyRate,
} = require("./usageAccounting");

const DEFAULT_MONTHLY_LIMIT_MINUTES = 30;
const SAVE_INTERVAL_MS = 1000;

function monthKey(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  return `${year}-${month}`;
}

function readLimitSeconds(env = process.env) {
  const minutes = Number(env.JP_DUB_MONTHLY_LIMIT_MINUTES || env.JP_DUB_DAILY_LIMIT_MINUTES || DEFAULT_MONTHLY_LIMIT_MINUTES);
  if (!Number.isFinite(minutes) || minutes <= 0) {
    return DEFAULT_MONTHLY_LIMIT_MINUTES * 60;
  }
  return Math.floor(minutes * 60);
}

function readMonthlyLimitEnabled(env = process.env) {
  const configured = env.JP_DUB_MONTHLY_LIMIT_ENABLED;
  if (configured !== undefined) {
    return ["1", "true", "yes", "on"].includes(String(configured || "").toLowerCase());
  }
  const freeTierMode = ["1", "true", "yes", "on"].includes(String(env.JP_DUB_FREE_TIER_MODE || "").toLowerCase());
  return !freeTierMode && Boolean(env.JP_DUB_MONTHLY_LIMIT_MINUTES || env.JP_DUB_DAILY_LIMIT_MINUTES);
}

class BillingGuard {
  constructor(options = {}) {
    if (typeof options === "number") options = { limitSeconds: options, monthlyLimitEnabled: true, storagePath: null };
    this.monthlyLimitEnabled = options.monthlyLimitEnabled ?? readMonthlyLimitEnabled(options.env || process.env);
    this.limitSeconds = options.limitSeconds || readLimitSeconds(options.env || process.env);
    this.storagePath = options.storagePath === undefined ? defaultStoragePath() : options.storagePath;
    this.month = monthKey();
    this.usedSeconds = 0;
    this.outputSeconds = 0;
    this.tokenUsage = emptyTokenUsage();
    this.usdJpyRate = readUsdJpyRate();
    this.dirty = false;
    this.lastSavedAt = 0;
    this.load();
  }

  refreshPeriod(now = new Date()) {
    const currentMonth = monthKey(now);
    if (currentMonth !== this.month) {
      this.month = currentMonth;
      this.usedSeconds = 0;
      this.outputSeconds = 0;
      this.tokenUsage = emptyTokenUsage();
      this.markDirty();
      this.save(true);
    }
  }

  canUse(additionalSeconds = 0) {
    this.refreshPeriod();
    if (!this.monthlyLimitEnabled) return true;
    return this.usedSeconds + additionalSeconds <= this.limitSeconds;
  }

  record(seconds) {
    this.refreshPeriod();
    this.usedSeconds += Math.max(0, seconds);
    this.markDirty();
    this.save();
  }

  recordOutput(seconds) {
    this.refreshPeriod();
    this.outputSeconds += Math.max(0, seconds);
    this.markDirty();
    this.save();
  }

  recordTokens(delta) {
    this.refreshPeriod();
    this.tokenUsage.inputTokens += positiveInteger(delta.inputTokens);
    this.tokenUsage.outputTokens += positiveInteger(delta.outputTokens);
    this.tokenUsage.totalTokens += positiveInteger(delta.totalTokens);
    this.tokenUsage.unknownTokens += positiveInteger(delta.unknownTokens);
    this.markDirty();
    this.save();
  }

  setLimitSeconds(limitSeconds, options = {}) {
    const normalized = positiveNumber(limitSeconds);
    if (!normalized) {
      throw new Error("invalid_limit");
    }
    this.monthlyLimitEnabled = options.enabled ?? true;
    this.limitSeconds = Math.floor(normalized);
    this.markDirty();
    this.save(true);
  }

  disableMonthlyLimit() {
    this.monthlyLimitEnabled = false;
    this.markDirty();
    this.save(true);
  }

  resetUsage() {
    this.refreshPeriod();
    const backupPath = backupUsageFile(this.storagePath);
    this.usedSeconds = 0;
    this.outputSeconds = 0;
    this.tokenUsage = emptyTokenUsage();
    this.markDirty();
    this.save(true);
    return backupPath;
  }

  snapshot() {
    this.refreshPeriod();
    this.save();
    const estimatedUsage = estimateAudioTokensFromSeconds(this.usedSeconds, this.outputSeconds);
    const displayUsage = maxUsage(this.tokenUsage, estimatedUsage);
    return {
      period: "month",
      monthlyLimitEnabled: this.monthlyLimitEnabled,
      month: this.month,
      limitSeconds: this.limitSeconds,
      usedSeconds: Math.round(this.usedSeconds),
      outputSeconds: Math.round(this.outputSeconds),
      remainingSeconds: this.monthlyLimitEnabled ? Math.max(0, Math.round(this.limitSeconds - this.usedSeconds)) : null,
      usage: { ...this.tokenUsage },
      estimatedUsage,
      displayUsage,
      cost: estimateLiveTranslateCost(displayUsage, this.usdJpyRate),
    };
  }

  flush() {
    this.save(true);
  }

  load() {
    if (!this.storagePath) return;
    const data = readJson(this.storagePath);
    if (!data || data.month !== this.month) return;
    this.usedSeconds = positiveNumber(data.usedSeconds);
    this.outputSeconds = positiveNumber(data.outputSeconds);
    this.tokenUsage = {
      inputTokens: positiveInteger(data.inputTokens),
      outputTokens: positiveInteger(data.outputTokens),
      totalTokens: positiveInteger(data.totalTokens),
      unknownTokens: positiveInteger(data.unknownTokens),
    };
  }

  markDirty() {
    this.dirty = true;
  }

  save(force = false) {
    if (!this.storagePath || !this.dirty) return;
    const now = Date.now();
    if (!force && now - this.lastSavedAt < SAVE_INTERVAL_MS) return;
    fs.mkdirSync(path.dirname(this.storagePath), { recursive: true });
    fs.writeFileSync(this.storagePath, `${JSON.stringify({
      version: 1,
      month: this.month,
      limitSeconds: this.limitSeconds,
      usedSeconds: this.usedSeconds,
      outputSeconds: this.outputSeconds,
      ...this.tokenUsage,
      updatedAt: new Date().toISOString(),
    }, null, 2)}\n`);
    this.dirty = false;
    this.lastSavedAt = now;
  }
}

function defaultStoragePath() {
  if (process.env.JP_DUB_USAGE_FILE) {
    return path.resolve(process.env.JP_DUB_USAGE_FILE);
  }
  return path.resolve(__dirname, "..", "..", "..", "..", "tmp", "jp-dub-usage.json");
}

function readLocalUsageSummary(options = {}) {
  const storagePath = options.storagePath || defaultStoragePath();
  const monthlyLimitEnabled = options.monthlyLimitEnabled ?? readMonthlyLimitEnabled(options.env || process.env);
  const limitSeconds = positiveNumber(options.limitSeconds) || readLimitSeconds(options.env || process.env);
  const data = readJson(storagePath);
  const currentMonth = monthKey(options.now || new Date());
  const month = String(data?.month || currentMonth);
  const sameMonth = month === currentMonth;
  const usedSeconds = sameMonth ? positiveNumber(data?.usedSeconds) : 0;
  const outputSeconds = sameMonth ? positiveNumber(data?.outputSeconds) : 0;
  const remainingSeconds = monthlyLimitEnabled ? Math.max(0, Math.round(limitSeconds - usedSeconds)) : null;
  return {
    exists: Boolean(data),
    storagePath,
    period: "month",
    monthlyLimitEnabled,
    month,
    limitSeconds,
    usedSeconds: Math.round(usedSeconds),
    outputSeconds: Math.round(outputSeconds),
    remainingSeconds,
    limitMinutes: limitSeconds / 60,
    usedMinutes: usedSeconds / 60,
    remainingMinutes: remainingSeconds == null ? null : remainingSeconds / 60,
    state: usageState({ exists: Boolean(data), monthlyLimitEnabled, remainingSeconds, limitSeconds }),
  };
}

function usageState(summary) {
  if (!summary.monthlyLimitEnabled) return "disabled";
  if (!summary.exists) return "missing";
  if (summary.remainingSeconds <= 0) return "exhausted";
  if (summary.remainingSeconds <= Math.min(120, Math.max(1, summary.limitSeconds * 0.1))) return "low";
  return "ok";
}

function emptyTokenUsage() {
  return {
    inputTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
    unknownTokens: 0,
  };
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

function backupUsageFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return "";
  const backupPath = path.join(
    path.dirname(filePath),
    `jp-dub-usage.json.reset-backup.${timestamp(new Date())}`,
  );
  fs.mkdirSync(path.dirname(backupPath), { recursive: true });
  fs.renameSync(filePath, backupPath);
  return backupPath;
}

function timestamp(date) {
  const pad = (value) => String(value).padStart(2, "0");
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
  ].join("") + "-" + [
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
  ].join("");
}

function positiveNumber(value) {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return value;
}

function positiveInteger(value) {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.round(value);
}

module.exports = {
  BillingGuard,
  defaultStoragePath,
  readLocalUsageSummary,
  readLimitSeconds,
  readMonthlyLimitEnabled,
};
