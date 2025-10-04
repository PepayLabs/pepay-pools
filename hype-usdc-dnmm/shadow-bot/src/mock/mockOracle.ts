import {
  HcOracleSample,
  OracleReaderAdapter,
  OracleSnapshot,
  PythOracleSample
} from '../types.js';
import { ScenarioEngine } from './scenarios.js';
import { MockClock } from './mockClock.js';

const BPS = 10_000n;

function toWad(value: number): bigint {
  return BigInt(Math.round(value * 1e18));
}

function applyBps(base: bigint, bps: number): bigint {
  return (base * (BPS + BigInt(Math.round(bps)))) / BPS;
}

function computeBidAsk(midWad: bigint, spreadBps: number): { bid: bigint; ask: bigint } {
  if (spreadBps <= 0) {
    return { bid: midWad, ask: midWad };
  }
  const half = (midWad * BigInt(spreadBps)) / (2n * BPS);
  return {
    bid: midWad - half,
    ask: midWad + half
  };
}

export class MockOracleReader implements OracleReaderAdapter {
  constructor(private readonly engine: ScenarioEngine, private readonly clock: MockClock) {}

  async sample(): Promise<OracleSnapshot> {
    const timestampMs = this.clock.now();
    const params = this.engine.getParams(timestampMs);
    const midBaseWad = toWad(params.mid);
    const hcMid = applyBps(midBaseWad, params.delta_bps);
    const { bid, ask } = computeBidAsk(hcMid, params.spread_bps);

    const hcSample: HcOracleSample = {
      status: 'ok',
      reason: 'OK',
      midWad: hcMid,
      bidWad: bid,
      askWad: ask,
      spreadBps: params.spread_bps,
      statusDetail: params.aomq ? 'aomq:scenario' : undefined
    };

    const pythSample: PythOracleSample = params.pyth_stale
      ? {
          status: 'ok',
          reason: 'OK',
          midWad: midBaseWad,
          confBps: params.conf_bps,
          publishTimeSec: this.clock.nowSeconds() - 120,
          statusDetail: 'stale'
        }
      : {
          status: 'ok',
          reason: 'OK',
          midWad: midBaseWad,
          confBps: params.conf_bps,
          publishTimeSec: this.clock.nowSeconds()
        };

    return {
      hc: hcSample,
      pyth: pythSample,
      observedAtMs: timestampMs
    };
  }
}
