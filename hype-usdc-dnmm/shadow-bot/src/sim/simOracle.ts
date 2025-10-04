import {
  HcOracleSample,
  OracleReaderAdapter,
  OracleSnapshot,
  PythOracleSample
} from '../types.js';

export class SimOracleReader implements OracleReaderAdapter {
  private readonly midWad: bigint;

  constructor(midWad: bigint = 1_000_000_000_000_000_000n) {
    this.midWad = midWad;
  }

  async sample(): Promise<OracleSnapshot> {
    const hc: HcOracleSample = {
      status: 'ok',
      reason: 'OK',
      midWad: this.midWad,
      bidWad: this.midWad - 10_000_000_000_000n,
      askWad: this.midWad + 10_000_000_000_000n,
      spreadBps: 20,
      ageSec: 0
    };
    const pyth: PythOracleSample = {
      status: 'ok',
      reason: 'OK',
      midWad: this.midWad,
      confBps: 15,
      publishTimeSec: Math.floor(Date.now() / 1_000)
    };
    return {
      hc,
      pyth,
      observedAtMs: Date.now()
    };
  }
}
