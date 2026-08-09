const fs = require("fs");
const path = require("path");

const DEFAULT_CAPTURE_SECONDS = 4;
const DEFAULT_SAMPLE_RATE = 24000;
const DEFAULT_CHANNELS = 1;
const DEFAULT_OUTPUT_DIR = path.resolve(__dirname, "..", "..", "..", "..", "tmp", "diagnostics");

class FirstOutputWavCapture {
  constructor(options = {}) {
    this.enabled = options.enabled === true;
    this.sampleRate = options.sampleRate || DEFAULT_SAMPLE_RATE;
    this.channels = options.channels || DEFAULT_CHANNELS;
    this.outputDir = options.outputDir || DEFAULT_OUTPUT_DIR;
    this.filenamePrefix = options.filenamePrefix || "jp-dub-first-output";
    this.captureBytes = Math.max(1, Math.floor(options.captureSeconds || DEFAULT_CAPTURE_SECONDS)) *
      this.sampleRate * this.channels * 2;
    this.bytes = [];
    this.totalBytes = 0;
    this.filePath = "";
    this.finished = false;
  }

  addAudio(buffer) {
    if (!this.enabled || this.finished || !buffer?.length) return "";
    const remaining = this.captureBytes - this.totalBytes;
    if (remaining <= 0) return this.finish();
    const chunk = Buffer.from(buffer.subarray(0, remaining));
    this.bytes.push(chunk);
    this.totalBytes += chunk.length;
    if (this.totalBytes >= this.captureBytes) return this.finish();
    return "";
  }

  flush() {
    return this.finish();
  }

  finish() {
    if (!this.enabled || this.finished || this.totalBytes === 0) return this.filePath;
    fs.mkdirSync(this.outputDir, { recursive: true });
    const pcm = Buffer.concat(this.bytes, this.totalBytes);
    this.filePath = path.join(this.outputDir, `${this.filenamePrefix}-${timestamp()}.wav`);
    fs.writeFileSync(this.filePath, makeWavBuffer(pcm, {
      sampleRate: this.sampleRate,
      channels: this.channels,
    }));
    this.finished = true;
    this.bytes = [];
    return this.filePath;
  }
}

function makeWavBuffer(pcm, options = {}) {
  const sampleRate = options.sampleRate || DEFAULT_SAMPLE_RATE;
  const channels = options.channels || DEFAULT_CHANNELS;
  const byteRate = sampleRate * channels * 2;
  const blockAlign = channels * 2;
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

function timestamp() {
  return new Date().toISOString().replace(/[:.]/g, "-");
}

module.exports = {
  FirstOutputWavCapture,
  makeWavBuffer,
};
