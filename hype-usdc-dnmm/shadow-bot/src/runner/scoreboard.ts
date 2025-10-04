import { formatUnits } from 'ethers';
import {
  BenchmarkId,
  BenchmarkTradeResult,
  RunSettingDefinition,
  ScoreboardAccumulatorSnapshot,
  ScoreboardAggregatorState,
  IntentMatchSnapshot,
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
  lvrBpsSum: number;
  lvrCount: number;
  effectiveFeeAfterRebateSum: number;
  effectiveFeeCount: number;
  previewStaleRejects: number;
  timeoutRejects: number;
  riskExposure: number;
  sigmaSamples: number;
}

interface IntentMatch {
  readonly success: boolean;
  readonly price: number;
  readonly side: 'base_in' | 'quote_in';
}

interface PriceAccumulator {
  sum: number;
  count: number;
}

interface ScoreboardOptions {
  readonly baseDecimals: number;
  readonly quoteDecimals: number;
}

interface ScoreboardAggregatorOptions extends ScoreboardOptions {
  readonly initialState?: ScoreboardAggregatorState;
}

export class ScoreboardAggregator {
  private readonly map = new Map<string, Accumulator>();
  private readonly makerNotional = new Map<string, number>();
  private readonly intentComparisons = new Map<string, Map<string, Map<BenchmarkId, IntentMatch>>>();
  private readonly options: ScoreboardOptions;

  constructor(
    settings: readonly RunSettingDefinition[],
    benchmarks: readonly BenchmarkId[],
    options: ScoreboardAggregatorOptions
  ) {
    this.options = options;
    this.bootstrap(settings, benchmarks, options.initialState);
  }

  recordTrade(settingId: string, benchmark: BenchmarkId, result: BenchmarkTradeResult): void {
    const bucket = this.get(settingId, benchmark);
    bucket.intents += 1;
    if (result.success) {
      bucket.trades += 1;
      bucket.pnlTotal += result.pnlQuote;
      bucket.feeSum += result.feeBpsUsed;
      bucket.slippageSum += result.slippageBpsVsMid;
      if (result.pnlQuote > 0) {
        bucket.wins += 1;
      }
      if (result.feeLvrBps !== undefined) {
        bucket.lvrBpsSum += result.feeLvrBps;
        bucket.lvrCount += 1;
      }
      const effectiveFee =
        result.feeBpsUsed + (result.feeLvrBps ?? 0) - (result.rebateBps ?? 0);
      if (Number.isFinite(effectiveFee)) {
        bucket.effectiveFeeAfterRebateSum += effectiveFee;
        bucket.effectiveFeeCount += 1;
      }
    } else {
      bucket.rejects += 1;
    }
    if (result.aomqClamped) {
      bucket.aomq += 1;
    }
    if (!result.success && result.rejectReason) {
      const reason = result.rejectReason.toLowerCase();
      if (reason.includes('stale')) {
        bucket.previewStaleRejects += 1;
      }
      if (reason.includes('timeout') || reason.includes('ttl')) {
        bucket.timeoutRejects += 1;
      }
    }
    if (result.success && result.sigmaBps && result.inventoryQuote !== undefined) {
      const sigma = result.sigmaBps / 10_000;
      if (sigma > 0) {
        const inventoryQuote = Math.abs(toFloat(result.inventoryQuote, this.options.quoteDecimals));
        bucket.riskExposure += inventoryQuote * sigma;
        bucket.sigmaSamples += 1;
      }
    }

    this.trackIntent(settingId, benchmark, result);
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

  exportState(): ScoreboardAggregatorState {
    const buckets: Record<string, ScoreboardAccumulatorSnapshot> = {};
    for (const [bucketKey, acc] of this.map.entries()) {
      buckets[bucketKey] = { ...acc };
    }
    const makerNotional: Record<string, number> = {};
    for (const [settingId, notional] of this.makerNotional.entries()) {
      makerNotional[settingId] = notional;
    }
    const intentComparisons: Record<string, Record<string, Record<BenchmarkId, IntentMatchSnapshot>>> = {};
    for (const [settingId, intents] of this.intentComparisons.entries()) {
      const intentsRecord: Record<string, Record<BenchmarkId, IntentMatchSnapshot>> = {};
      for (const [intentId, matches] of intents.entries()) {
        const matchRecord: Record<BenchmarkId, IntentMatchSnapshot> = {} as Record<BenchmarkId, IntentMatchSnapshot>;
        for (const [benchmark, match] of matches.entries()) {
          matchRecord[benchmark] = { ...match };
        }
        intentsRecord[intentId] = matchRecord;
      }
      intentComparisons[settingId] = intentsRecord;
    }
    return { buckets, makerNotional, intentComparisons };
  }

  buildRows(): ScoreboardRow[] {
    const priceImprovement = this.computePriceImprovement();
    const rows: ScoreboardRow[] = [];
    for (const [bucketKey, acc] of this.map.entries()) {
      const [settingId, benchmark] = bucketKey.split('::') as [string, BenchmarkId];
      const makerNotional = this.makerNotional.get(settingId) ?? 1;
      const trades = acc.trades;
      const intents = Math.max(acc.intents, trades + acc.rejects);
      const pnlPerBps = makerNotional === 0 ? 0 : (acc.pnlTotal / makerNotional) * 10_000;
      const routerWinRate = intents === 0 ? 0 : (trades / intents) * 100;
      const avgEffectiveFee = acc.effectiveFeeCount === 0 ? 0 : acc.effectiveFeeAfterRebateSum / acc.effectiveFeeCount;
      const lvrCaptureBps = acc.lvrCount === 0 ? 0 : acc.lvrBpsSum / acc.lvrCount;
      const aomqRate = trades === 0 ? 0 : (acc.aomq / trades) * 100;
      const previewStaleRatio = intents === 0 ? 0 : (acc.previewStaleRejects / intents) * 100;
      const timeoutRate = intents === 0 ? 0 : (acc.timeoutRejects / intents) * 100;
      const pnlPerRisk = acc.riskExposure === 0 ? 0 : acc.pnlTotal / acc.riskExposure;
      const priceDelta = priceImprovement.get(bucketKey) ?? (benchmark === 'cpmm' ? 0 : undefined);
      rows.push({
        settingId,
        benchmark,
        trades,
        pnlQuoteTotal: acc.pnlTotal,
        pnlPerMmNotionalBps: pnlPerBps,
        pnlPerRisk,
        winRatePct: trades === 0 ? 0 : (acc.wins / trades) * 100,
        routerWinRatePct: routerWinRate,
        avgFeeBps: trades === 0 ? 0 : acc.feeSum / trades,
        avgFeeAfterRebateBps: avgEffectiveFee,
        avgSlippageBps: trades === 0 ? 0 : acc.slippageSum / trades,
        twoSidedUptimePct:
          acc.twoSidedSamples === 0 ? 0 : (acc.twoSidedSatisfied / acc.twoSidedSamples) * 100,
        rejectRatePct: intents === 0 ? 0 : (acc.rejects / intents) * 100,
        aomqClampsTotal: acc.aomq,
        aomqClampsRatePct: aomqRate,
        lvrCaptureBps,
        priceImprovementVsCpmmBps: priceDelta,
        previewStalenessRatioPct: previewStaleRatio,
        timeoutExpiryRatePct: timeoutRate,
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
    const bucketKey = key(settingId, benchmark);
    let bucket = this.map.get(bucketKey);
    if (!bucket) {
      bucket = createAccumulator();
      this.map.set(bucketKey, bucket);
    }
    return bucket;
  }

  private bootstrap(
    settings: readonly RunSettingDefinition[],
    benchmarks: readonly BenchmarkId[],
    state: ScoreboardAggregatorState | undefined
  ): void {
    if (state) {
      for (const [bucketKey, snapshot] of Object.entries(state.buckets)) {
        this.map.set(bucketKey, { ...snapshot });
      }
      for (const [settingId, notional] of Object.entries(state.makerNotional)) {
        this.makerNotional.set(settingId, notional);
      }
      for (const [settingId, intents] of Object.entries(state.intentComparisons)) {
        const intentMap = new Map<string, Map<BenchmarkId, IntentMatch>>();
        for (const [intentId, matches] of Object.entries(intents)) {
          const matchMap = new Map<BenchmarkId, IntentMatch>();
          for (const [benchmarkId, snapshot] of Object.entries(matches) as [BenchmarkId, IntentMatchSnapshot][]) {
            matchMap.set(benchmarkId, { ...snapshot });
          }
          intentMap.set(intentId, matchMap);
        }
        this.intentComparisons.set(settingId, intentMap);
      }
    }

    for (const setting of settings) {
      if (!this.makerNotional.has(setting.id)) {
        this.makerNotional.set(setting.id, setting.makerParams.S0Notional);
      }
      const settingMapKey = state?.intentComparisons?.[setting.id];
      if (settingMapKey === undefined && !this.intentComparisons.has(setting.id)) {
        this.intentComparisons.set(setting.id, new Map());
      }
      for (const benchmark of benchmarks) {
        const bucketKey = key(setting.id, benchmark);
        if (!this.map.has(bucketKey)) {
          this.map.set(bucketKey, createAccumulator());
        }
      }
    }
  }

  private trackIntent(settingId: string, benchmark: BenchmarkId, result: BenchmarkTradeResult): void {
    if (!result.success) {
      return;
    }
    const price = computePrice(result, this.options.baseDecimals, this.options.quoteDecimals);
    if (!Number.isFinite(price) || price <= 0) {
      return;
    }
    let settingMap = this.intentComparisons.get(settingId);
    if (!settingMap) {
      settingMap = new Map();
      this.intentComparisons.set(settingId, settingMap);
    }
    let intentMap = settingMap.get(result.intent.id);
    if (!intentMap) {
      intentMap = new Map();
      settingMap.set(result.intent.id, intentMap);
    }
    intentMap.set(benchmark, {
      success: result.success,
      price,
      side: result.intent.side
    });
  }

  private computePriceImprovement(): Map<string, number> {
    const priceMap = new Map<string, PriceAccumulator>();
    for (const [settingId, intents] of this.intentComparisons.entries()) {
      for (const intent of intents.values()) {
        const cpmm = intent.get('cpmm');
        if (!cpmm || !cpmm.success || cpmm.price <= 0) {
          continue;
        }
        for (const [benchmark, match] of intent.entries()) {
          if (benchmark === 'cpmm' || !match.success || match.price <= 0) {
            continue;
          }
          const deltaBps = ((match.price - cpmm.price) / cpmm.price) * 10_000;
          const bucketKey = key(settingId, benchmark);
          let acc = priceMap.get(bucketKey);
          if (!acc) {
            acc = { sum: 0, count: 0 };
            priceMap.set(bucketKey, acc);
          }
          acc.sum += deltaBps;
          acc.count += 1;
        }
      }
    }
    const averages = new Map<string, number>();
    for (const [bucketKey, acc] of priceMap.entries()) {
      if (acc.count === 0) continue;
      averages.set(bucketKey, acc.sum / acc.count);
    }
    return averages;
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
    twoSidedSatisfied: 0,
    lvrBpsSum: 0,
    lvrCount: 0,
    effectiveFeeAfterRebateSum: 0,
    effectiveFeeCount: 0,
    previewStaleRejects: 0,
    timeoutRejects: 0,
    riskExposure: 0,
    sigmaSamples: 0
  };
}

function toFloat(value: bigint, decimals: number): number {
  return Number.parseFloat(formatUnits(value, decimals));
}

function computePrice(
  result: BenchmarkTradeResult,
  baseDecimals: number,
  quoteDecimals: number
): number {
  const amountIn = result.appliedAmountIn ?? result.amountIn;
  if (amountIn === 0n || result.amountOut === 0n) {
    return 0;
  }
  if (result.intent.side === 'base_in') {
    const base = toFloat(amountIn, baseDecimals);
    const quote = toFloat(result.amountOut, quoteDecimals);
    return base === 0 ? 0 : quote / base;
  }
  const quote = toFloat(amountIn, quoteDecimals);
  const base = toFloat(result.amountOut, baseDecimals);
  return base === 0 ? 0 : quote / base;
}
