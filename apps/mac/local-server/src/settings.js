const fs = require("fs");
const path = require("path");
const { localEnvPath, parseEnvLine } = require("./localEnv");

function normalizeLimitMinutes(value) {
  const minutes = Number(value);
  if (!Number.isFinite(minutes) || minutes <= 0) {
    throw new Error("invalid_limit_minutes");
  }
  return Math.min(24 * 60, Math.max(1, minutes));
}

function normalizeMonthlyLimitEnabled(value) {
  return ["1", "true", "yes", "on"].includes(String(value || "").toLowerCase());
}

function updateMonthlyLimitMinutes(minutes, options = {}) {
  const normalized = normalizeLimitMinutes(minutes);
  const filePath = options.filePath || localEnvPath();
  updateEnvValue(filePath, "JP_DUB_MONTHLY_LIMIT_ENABLED", "true");
  updateEnvValue(filePath, "JP_DUB_MONTHLY_LIMIT_MINUTES", formatMinutes(normalized));
  return normalized;
}

function updateMonthlyLimitEnabled(enabled, options = {}) {
  const normalized = Boolean(enabled);
  const filePath = options.filePath || localEnvPath();
  updateEnvValue(filePath, "JP_DUB_MONTHLY_LIMIT_ENABLED", normalized ? "true" : "false");
  return normalized;
}

function updateEnvValue(filePath, key, value) {
  const existing = fs.existsSync(filePath) ? fs.readFileSync(filePath, "utf8") : "";
  let lines = existing.split(/\r?\n/);
  if (lines.length === 1 && lines[0] === "") lines = [];
  let replaced = false;
  lines = lines.map((line) => {
    if (replaced) return line;
    const parsed = parseEnvLine(line);
    if (parsed?.[0] !== key) return line;
    replaced = true;
    return `${key}=${value}`;
  });
  if (!replaced) lines.push(`${key}=${value}`);
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${lines.join("\n").replace(/\n*$/g, "")}\n`);
}

function formatMinutes(minutes) {
  if (Math.round(minutes) === minutes) return String(minutes);
  return minutes.toFixed(2).replace(/0+$/g, "").replace(/\.$/g, "");
}

module.exports = {
  normalizeMonthlyLimitEnabled,
  normalizeLimitMinutes,
  updateMonthlyLimitEnabled,
  updateMonthlyLimitMinutes,
};
