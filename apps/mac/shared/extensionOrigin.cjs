const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const DEFAULT_MANIFEST_PATH = path.resolve(__dirname, "../extension/manifest.json");
const EXPLICIT_ORIGIN_ENV_KEYS = ["MIMI_EXTENSION_ORIGIN", "JP_DUB_ALLOWED_EXTENSION_ORIGIN"];
const CANONICAL_EXTENSION_ID = "oknekoaclmnljnlpmffphpiflcdeibgg";
const CANONICAL_EXTENSION_ORIGIN = `chrome-extension://${CANONICAL_EXTENSION_ID}`;

function resolveExtensionOrigin(options = {}) {
  return resolveExtensionOriginDetails(options).origin;
}

function resolveExtensionOriginDetails(options = {}) {
  const env = options.env || process.env;
  const explicit = explicitOriginFromEnv(env);
  if (explicit) {
    return {
      origin: normalizeExtensionOrigin(explicit),
      source: "env",
      extensionId: extensionIdFromOrigin(explicit),
    };
  }

  const manifestPath = options.manifestPath || DEFAULT_MANIFEST_PATH;
  const manifest = readManifest(manifestPath, options.fs || fs);
  const extensionId = extensionIdFromManifestKey(manifest.key);
  if (!extensionId) return { origin: "", source: "missing", extensionId: "" };
  return {
    origin: `chrome-extension://${extensionId}`,
    source: "manifest_key",
    extensionId,
  };
}

function explicitOriginFromEnv(env) {
  for (const key of EXPLICIT_ORIGIN_ENV_KEYS) {
    if (env?.[key]) return env[key];
  }
  return "";
}

function readManifest(manifestPath, fsApi) {
  try {
    return JSON.parse(fsApi.readFileSync(manifestPath, "utf8"));
  } catch {
    return {};
  }
}

function extensionIdFromManifestKey(key) {
  const normalized = String(key || "").replace(/\s+/g, "");
  if (!normalized) return "";
  const digest = crypto.createHash("sha256").update(Buffer.from(normalized, "base64")).digest();
  return Array.from(digest.subarray(0, 16), (byte) => {
    const high = String.fromCharCode(97 + ((byte >> 4) & 0xf));
    const low = String.fromCharCode(97 + (byte & 0xf));
    return `${high}${low}`;
  }).join("");
}

function normalizeExtensionOrigin(value, options = {}) {
  const text = String(value || "").trim().replace(/\/+$/, "");
  const match = text.match(/^chrome-extension:\/\/([a-p]{32})$/);
  if (!match) throw new Error("invalid_extension_origin");
  return options.trailingSlash ? `${text}/` : text;
}

function extensionIdFromOrigin(value) {
  return normalizeExtensionOrigin(value).slice("chrome-extension://".length);
}

module.exports = {
  CANONICAL_EXTENSION_ID,
  CANONICAL_EXTENSION_ORIGIN,
  DEFAULT_MANIFEST_PATH,
  EXPLICIT_ORIGIN_ENV_KEYS,
  extensionIdFromManifestKey,
  extensionIdFromOrigin,
  normalizeExtensionOrigin,
  resolveExtensionOrigin,
  resolveExtensionOriginDetails,
};
