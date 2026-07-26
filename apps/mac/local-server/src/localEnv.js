const fs = require("fs");
const path = require("path");

function loadLocalEnv(filename = ".env") {
  if (process.env.JP_DUB_SKIP_DOTENV === "1") return false;
  const filePath = localEnvPath(filename);
  if (!fs.existsSync(filePath)) return false;
  const content = fs.readFileSync(filePath, "utf8");
  for (const line of content.split(/\r?\n/)) {
    const parsed = parseEnvLine(line);
    if (!parsed) continue;
    const [key, value] = parsed;
    if (process.env[key] === undefined) process.env[key] = value;
  }
  return true;
}

function localEnvPath(filename = ".env") {
  if (filename === ".env" && process.env.JP_DUB_ENV_FILE) {
    return path.resolve(process.env.JP_DUB_ENV_FILE);
  }
  return path.resolve(__dirname, "..", filename);
}

function localEnvDiagnostics(filename = ".env") {
  const filePath = localEnvPath(filename);
  if (process.env.JP_DUB_SKIP_DOTENV === "1") {
    return { filePath, skipped: true, exists: false, hasGeminiKeyLine: false };
  }
  if (!fs.existsSync(filePath)) {
    return { filePath, skipped: false, exists: false, hasGeminiKeyLine: false };
  }
  const content = fs.readFileSync(filePath, "utf8");
  return {
    filePath,
    skipped: false,
    exists: true,
    hasGeminiKeyLine: content.split(/\r?\n/).some((line) => {
      const parsed = parseEnvLine(line);
      return parsed?.[0] === "GEMINI_API_KEY";
    }),
  };
}

function parseEnvLine(line) {
  let trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) return null;
  if (trimmed.startsWith("export ")) trimmed = trimmed.slice("export ".length).trim();
  const index = trimmed.indexOf("=");
  if (index <= 0) return null;
  const key = trimmed.slice(0, index).trim();
  const rawValue = trimmed.slice(index + 1).trim();
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) return null;
  return [key, unquote(rawValue)];
}

function unquote(value) {
  if (
    (value.startsWith('"') && value.endsWith('"')) ||
    (value.startsWith("'") && value.endsWith("'"))
  ) {
    return value.slice(1, -1);
  }
  return value;
}

module.exports = {
  localEnvDiagnostics,
  localEnvPath,
  loadLocalEnv,
  parseEnvLine,
};
