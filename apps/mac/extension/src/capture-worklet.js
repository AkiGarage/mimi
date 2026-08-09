const CAPTURE_FRAME_SIZE = 4096;

class JpDubCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = new Float32Array(CAPTURE_FRAME_SIZE);
    this.offset = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;

    const frameCount = input[0]?.length || 0;
    for (let frame = 0; frame < frameCount; frame += 1) {
      let mixed = 0;
      for (let channel = 0; channel < input.length; channel += 1) mixed += input[channel][frame] || 0;
      this.buffer[this.offset] = mixed / input.length;
      this.offset += 1;
      if (this.offset === this.buffer.length) this.flush();
    }
    return true;
  }

  flush() {
    const samples = this.buffer;
    this.buffer = new Float32Array(CAPTURE_FRAME_SIZE);
    this.offset = 0;
    this.port.postMessage({ type: "samples", sampleRate, samples }, [samples.buffer]);
  }
}

registerProcessor("jp-dub-capture", JpDubCaptureProcessor);
