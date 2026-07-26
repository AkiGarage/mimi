const fs = require("fs");
const path = require("path");

const DEFAULT_LOG_PATH = path.resolve(__dirname, "..", "..", "..", "..", "logs", "jp-dub-diagnostics.ndjson");
const DEFAULT_MAX_RECENT_EVENTS = 80;

class DiagnosticsLog {
  constructor(options = {}) {
    this.enabled = options.enabled !== false;
    this.logPath = options.logPath || DEFAULT_LOG_PATH;
    this.maxRecentEvents = options.maxRecentEvents || DEFAULT_MAX_RECENT_EVENTS;
    this.recent = [];
  }

  record(event, data = {}) {
    if (!this.enabled) return null;
    const entry = {
      ts: new Date().toISOString(),
      event,
      ...sanitizeValue(data),
    };
    this.recent.push(entry);
    if (this.recent.length > this.maxRecentEvents) this.recent.shift();
    fs.mkdirSync(path.dirname(this.logPath), { recursive: true });
    fs.appendFileSync(this.logPath, `${JSON.stringify(entry)}\n`);
    return entry;
  }

  snapshot() {
    return {
      enabled: this.enabled,
      logPath: this.enabled ? this.logPath : "",
      recent: this.recent.slice(),
    };
  }
}

function analyzePcm16le(buffer, options = {}) {
  const sampleRate = options.sampleRate || 24000;
  const samples = Math.floor((buffer?.length || 0) / 2);
  if (!samples) {
    return {
      bytes: buffer?.length || 0,
      samples: 0,
      durationMs: 0,
      peak: 0,
      peakNorm: 0,
      rms: 0,
      rmsNorm: 0,
      dcOffset: 0,
      clippedSamples: 0,
      zeroCrossings: 0,
    };
  }

  let peak = 0;
  let sum = 0;
  let sumSquares = 0;
  let clippedSamples = 0;
  let zeroCrossings = 0;
  let previousSign = 0;

  for (let index = 0; index < samples; index += 1) {
    const value = buffer.readInt16LE(index * 2);
    const absolute = Math.abs(value);
    if (absolute > peak) peak = absolute;
    if (absolute >= 32767) clippedSamples += 1;
    sum += value;
    sumSquares += value * value;
    const sign = value === 0 ? previousSign : Math.sign(value);
    if (previousSign && sign && sign !== previousSign) zeroCrossings += 1;
    if (sign) previousSign = sign;
  }

  const rms = Math.sqrt(sumSquares / samples);
  return {
    bytes: buffer.length,
    samples,
    durationMs: round((samples / sampleRate) * 1000, 1),
    peak,
    peakNorm: round(peak / 32768, 4),
    rms: Math.round(rms),
    rmsNorm: round(rms / 32768, 4),
    dcOffset: Math.round(sum / samples),
    clippedSamples,
    zeroCrossings,
  };
}

function makeSessionId() {
  return `s-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function sanitizeValue(value, key = "") {
  if (key && /authorization|secret|token|key/i.test(key)) return "[redacted]";
  if (value === null || value === undefined) return value;
  if (Buffer.isBuffer(value)) return `[buffer:${value.length}]`;
  if (Array.isArray(value)) return value.slice(0, 20).map((item) => sanitizeValue(item));
  if (typeof value === "string") return redactString(value).slice(0, 500);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value !== "object") return String(value).slice(0, 500);
  const output = {};
  for (const [childKey, childValue] of Object.entries(value)) {
    output[childKey] = sanitizeValue(childValue, childKey);
  }
  return output;
}

function redactString(value) {
  return value
    .replace(/(key|token|secret|authorization)=([^&\s]+)/gi, "$1=REDACTED")
    .replace(/AIza[0-9A-Za-z_-]{20,}/g, "REDACTED");
}

function round(value, precision) {
  const scale = 10 ** precision;
  return Math.round(value * scale) / scale;
}

module.exports = {
  DiagnosticsLog,
  analyzePcm16le,
  makeSessionId,
};
