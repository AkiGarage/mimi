const AUDIO_INPUT_USD_PER_MILLION_TOKENS = 3.5;
const AUDIO_OUTPUT_USD_PER_MILLION_TOKENS = 21;
const AUDIO_TOKENS_PER_SECOND = 25;
const DEFAULT_USD_JPY_RATE = 160;

function readUsdJpyRate(env = process.env) {
  const value = Number(env.JP_DUB_USD_JPY_RATE || DEFAULT_USD_JPY_RATE);
  if (!Number.isFinite(value) || value <= 0) return DEFAULT_USD_JPY_RATE;
  return value;
}

function estimateLiveTranslateCost(usage, usdJpyRate = readUsdJpyRate()) {
  const inputUsd = millionTokenCost(usage.inputTokens, AUDIO_INPUT_USD_PER_MILLION_TOKENS);
  const outputUsd = millionTokenCost(usage.outputTokens, AUDIO_OUTPUT_USD_PER_MILLION_TOKENS);
  const totalUsd = inputUsd + outputUsd;
  return {
    inputUsd,
    outputUsd,
    totalUsd,
    totalJpy: totalUsd * usdJpyRate,
    usdJpyRate,
    inputUsdPerMillionTokens: AUDIO_INPUT_USD_PER_MILLION_TOKENS,
    outputUsdPerMillionTokens: AUDIO_OUTPUT_USD_PER_MILLION_TOKENS,
  };
}

function estimateAudioTokensFromSeconds(inputSeconds = 0, outputSeconds = 0) {
  const inputTokens = Math.ceil(Math.max(0, inputSeconds) * AUDIO_TOKENS_PER_SECOND);
  const outputTokens = Math.ceil(Math.max(0, outputSeconds) * AUDIO_TOKENS_PER_SECOND);
  return withUnknownTokens({
    inputTokens,
    outputTokens,
    totalTokens: inputTokens + outputTokens,
  });
}

function maxUsage(left, right) {
  const inputTokens = Math.max(positiveInteger(left.inputTokens), positiveInteger(right.inputTokens));
  const outputTokens = Math.max(positiveInteger(left.outputTokens), positiveInteger(right.outputTokens));
  const totalTokens = Math.max(positiveInteger(left.totalTokens), positiveInteger(right.totalTokens), inputTokens + outputTokens);
  return withUnknownTokens({ inputTokens, outputTokens, totalTokens });
}

function normalizeUsageMetadata(metadata = {}) {
  const inputTokens = firstNumber(
    metadata.promptTokenCount,
    metadata.inputTokenCount,
    sumTokenDetails(metadata.promptTokensDetails),
    sumTokenDetails(metadata.inputTokensDetails)
  );
  const outputTokens = firstNumber(
    metadata.responseTokenCount,
    metadata.candidatesTokenCount,
    metadata.outputTokenCount,
    sumTokenDetails(metadata.responseTokensDetails),
    sumTokenDetails(metadata.candidatesTokensDetails)
  );
  const totalTokens = firstNumber(metadata.totalTokenCount, inputTokens + outputTokens);
  return withUnknownTokens({ inputTokens, outputTokens, totalTokens });
}

function cumulativeUsageDelta(previous, current) {
  if (!previous || current.totalTokens < previous.totalTokens) return current;
  return withUnknownTokens({
    inputTokens: Math.max(0, current.inputTokens - previous.inputTokens),
    outputTokens: Math.max(0, current.outputTokens - previous.outputTokens),
    totalTokens: Math.max(0, current.totalTokens - previous.totalTokens),
  });
}

function withUnknownTokens(usage) {
  const inputTokens = positiveInteger(usage.inputTokens);
  const outputTokens = positiveInteger(usage.outputTokens);
  const totalTokens = positiveInteger(usage.totalTokens);
  return {
    inputTokens,
    outputTokens,
    totalTokens,
    unknownTokens: Math.max(0, totalTokens - inputTokens - outputTokens),
  };
}

function millionTokenCost(tokens, usdPerMillion) {
  return positiveInteger(tokens) * usdPerMillion / 1_000_000;
}

function sumTokenDetails(details) {
  if (!Array.isArray(details)) return null;
  return details.reduce((sum, detail) => sum + positiveInteger(detail.tokenCount), 0);
}

function firstNumber(...values) {
  for (const value of values) {
    if (Number.isFinite(value)) return Math.max(0, Math.round(value));
  }
  return 0;
}

function positiveInteger(value) {
  if (!Number.isFinite(value) || value <= 0) return 0;
  return Math.round(value);
}

module.exports = {
  AUDIO_INPUT_USD_PER_MILLION_TOKENS,
  AUDIO_OUTPUT_USD_PER_MILLION_TOKENS,
  AUDIO_TOKENS_PER_SECOND,
  DEFAULT_USD_JPY_RATE,
  cumulativeUsageDelta,
  estimateAudioTokensFromSeconds,
  estimateLiveTranslateCost,
  maxUsage,
  normalizeUsageMetadata,
  readUsdJpyRate,
};
