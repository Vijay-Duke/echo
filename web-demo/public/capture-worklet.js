class CaptureProcessor extends AudioWorkletProcessor {
  constructor(opts) {
    super();
    this.targetRate = opts?.processorOptions?.targetRate || 24000;
    this.ratio = sampleRate / this.targetRate;
    this.acc = [];
    this.flushAt = this.targetRate / 10; // 100ms
  }
  process(inputs) {
    const ch = inputs[0]?.[0];
    if (!ch) return true;
    for (let i = 0; i < ch.length; i += this.ratio) {
      this.acc.push(ch[Math.floor(i)]);
    }
    while (this.acc.length >= this.flushAt) {
      const slice = this.acc.splice(0, this.flushAt);
      const i16 = new Int16Array(slice.length);
      for (let j = 0; j < slice.length; j++) {
        const s = Math.max(-1, Math.min(1, slice[j]));
        i16[j] = s < 0 ? s * 0x8000 : s * 0x7fff;
      }
      this.port.postMessage(i16.buffer, [i16.buffer]);
    }
    return true;
  }
}
registerProcessor('capture', CaptureProcessor);
