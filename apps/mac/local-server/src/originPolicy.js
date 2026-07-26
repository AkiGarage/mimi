function makeOriginPolicy(options = {}) {
  const allowedExtensionOrigin = normalizeOrigin(options.allowedExtensionOrigin || "");
  return function isAllowedOrigin(origin = "") {
    if (!origin || !allowedExtensionOrigin) return false;
    const normalized = normalizeOrigin(origin);
    if (!normalized.startsWith("chrome-extension://")) return false;
    return normalized === allowedExtensionOrigin;
  };
}

function normalizeOrigin(origin) {
  return origin.trim().replace(/\/+$/, "");
}

module.exports = {
  makeOriginPolicy,
  normalizeOrigin,
};
