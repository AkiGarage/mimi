const SUPPORTED_TARGET_LANGUAGE_CODES = new Set([
  "af", "ak", "sq", "am", "ar", "hy", "as", "az", "eu", "be", "bn", "bs",
  "bg", "my", "ca", "ceb", "zh", "hr", "cs", "da", "nl", "en", "et", "fo",
  "fil", "fi", "fr", "gl", "ka", "de", "el", "gu", "ha", "iw", "hi", "hu",
  "is", "id", "ga", "it", "ja", "kn", "kk", "km", "rw", "ko", "ku", "ky",
  "lo", "lv", "lt", "mk", "ms", "ml", "mt", "mi", "mr", "mn", "ne", "no",
  "or", "om", "ps", "fa", "pl", "pt", "pa", "qu", "ro", "rm", "ru", "sr",
  "sd", "si", "sk", "sl", "so", "st", "es", "sw", "sv", "tg", "ta", "te",
  "th", "tn", "tr", "tk", "uk", "ur", "uz", "vi", "cy", "fy", "wo", "yo",
  "zu",
]);

function normalizeTargetLanguageCode(value, fallback = "ja") {
  const normalized = String(value || fallback).trim().toLowerCase();
  return SUPPORTED_TARGET_LANGUAGE_CODES.has(normalized) ? normalized : "";
}

module.exports = {
  SUPPORTED_TARGET_LANGUAGE_CODES,
  normalizeTargetLanguageCode,
};
