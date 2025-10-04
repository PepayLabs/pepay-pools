import {
  BenchmarkId,
  BenchmarkTradeResult,
  RunSettingDefinition,
  ScoreboardRow
} from '../types.js';

interface Accumulator {
  trades: number;
  wins: number;
  pnlTotal: number;
  feeSum: number;
  slippageSum: number;
  rejects: number;
  intents: number;
  aomq: number;
  recenter: number;
  twoSidedSamples: number;
  twoSidedSatisfied: number;
}

export class ScoreboardAggregator {
  private readonly map = new Map<string, Accumulator>();
  private readonly makerNotional = new Map<string, number>();

  constructor(settings: readonly RunSettingDefinition[], benchmarks: readonly BenchmarkId[]) {
    for (const setting of settings) {
      this.makerNotional.set(setting.id, setting.makerParams.s0Notional);
      for (const benchmark of benchmarks) {
        this.map.set(key(setting.id, benchmark), createAccumulator());
      }
    }
  }

  recordTrade(settingId: string, benchmark: BenchmarkId, result: BenchmarkTradeResult): void {
    const bucket = this.get(settingId, benchmark);
    bucket.intents += 1;
    if (result.success) {
      bucket.trades += 1;
    } else {
      bucket.rejects += 1;
    }
    bucket.pnlTotal += result.pnlQuote;
    bucket.feeSum += result.feeBpsUsed;
    bucket.slippageSum += result.slippageBpsVsMid;
    if (result.success && result.pnlQuote > 0) {
      bucket.wins += 1;
    }
    if (result.aomqClamped) {
      bucket.aomq += 1;
    }
  }

  recordReject(settingId: string, benchmark: BenchmarkId): void {
    const bucket = this.get(settingId, benchmark);
    bucket.rejects += 1;
    bucket.intents += 1;
  }

  recordTwoSided(settingId: string, benchmark: BenchmarkId, twoSided: boolean): void {
    const bucket = this.get(settingId, benchmark);
    bucket.twoSidedSamples += 1;
    if (twoSided) {
      bucket.twoSidedSatisfied += 1;
    }
  }

  recordRecenter(settingId: string, benchmark: BenchmarkId): void {
    const bucket = this.get(settingId, benchmark);
    bucket.recenter += 1;
  }

  buildRows(): ScoreboardRow[] {
    const rows: ScoreboardRow[] = [];
    for (const [bucketKey, acc] of this.map.entries()) {
      const [settingId, benchmark] = bucketKey.split('::') as [string, BenchmarkId];
      const makerNotional = this.makerNotional.get(settingId) ?? 1;
      const trades = acc.trades;
      const intents = Math.max(acc.intents, trades + acc.rejects);
      const pnlPerBps = makerNotional === 0 ? 0 : (acc.pnlTotal / makerNotional) * 10_000;
      rows.push({
        settingId,
        benchmark,
        trades,
        pnlQuoteTotal: acc.pnlTotal,
        pnlPerMmNotionalBps: pnlPerBps,
        winRatePct: trades === 0 ? 0 : (acc.wins / trades) * 100,
        avgFeeBps: trades === 0 ? 0 : acc.feeSum / trades,
        avgSlippageBps: trades === 0 ? 0 : acc.slippageSum / trades,
        twoSidedUptimePct:
          acc.twoSidedSamples === 0 ? 0 : (acc.twoSidedSatisfied / acc.twoSidedSamples) * 100,
        rejectRatePct: intents === 0 ? 0 : (acc.rejects / intents) * 100,
        aomqClampsTotal: acc.aomq,
        recenterCommitsTotal: acc.recenter
      });
    }
    return rows.sort((a, b) => {
      if (a.settingId === b.settingId) {
        return a.benchmark.localeCompare(b.benchmark);
      }
      return a.settingId.localeCompare(b.settingId);
    });
  }

  private get(settingId: string, benchmark: BenchmarkId): Accumulator {
    const bucket = this.map.get(key(settingId, benchmark));
    if (!bucket) {
      const created = createAccumulator();
      this.map.set(key(settingId, benchmark), created);
      return created;
    }
    return bucket;
  }
}

function key(settingId: string, benchmark: BenchmarkId): string {
  return `${settingId}::${benchmark}`;
}

function createAccumulator(): Accumulator {
  return {
    trades: 0,
    wins: 0,
    pnlTotal: 0,
    feeSum: 0,
    slippageSum: 0,
    rejects: 0,
    intents: 0,
    aomq: 0,
    recenter: 0,
    twoSidedSamples: 0,
    twoSidedSatisfied: 0
  };
}
