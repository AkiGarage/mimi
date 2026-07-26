const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_PROVIDER = "gemini";
const DEFAULT_PROVIDER_PREFERENCE_PATH = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "Mimi",
  "provider-preference.json",
);

class ProviderPreferenceStore {
  constructor(options = {}) {
    this.filePath = options.filePath || DEFAULT_PROVIDER_PREFERENCE_PATH;
    this.provider = readSavedProvider(this.filePath);
  }

  get() {
    return this.provider;
  }

  set(value) {
    const provider = normalizeProviderPreference(value);
    if (!provider) throw new Error("unsupported_provider");
    persistProvider(this.filePath, provider);
    this.provider = provider;
    return provider;
  }
}

function normalizeProviderPreference(value) {
  const provider = String(value || "").trim().toLowerCase();
  return provider === "gemini" || provider === "openai" ? provider : "";
}

function readSavedProvider(filePath) {
  try {
    if (!fs.existsSync(filePath)) return DEFAULT_PROVIDER;
    const saved = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const rawProvider = String(saved?.provider || "").trim().toLowerCase();
    const provider = normalizeProviderPreference(rawProvider);
    if (provider) return provider;
    if (rawProvider === "xai" || rawProvider === "grok") {
      try {
        persistProvider(filePath, DEFAULT_PROVIDER);
      } catch {
        // A legacy preference must never prevent the server from using Gemini.
      }
    }
    return DEFAULT_PROVIDER;
  } catch {
    return DEFAULT_PROVIDER;
  }
}

function persistProvider(filePath, provider) {
  const directory = path.dirname(filePath);
  const temporaryPath = `${filePath}.${process.pid}.tmp`;
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  try {
    fs.writeFileSync(
      temporaryPath,
      `${JSON.stringify({ version: 1, provider })}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    fs.renameSync(temporaryPath, filePath);
  } finally {
    if (fs.existsSync(temporaryPath)) fs.rmSync(temporaryPath, { force: true });
  }
}

module.exports = {
  DEFAULT_PROVIDER,
  DEFAULT_PROVIDER_PREFERENCE_PATH,
  ProviderPreferenceStore,
  normalizeProviderPreference,
};
