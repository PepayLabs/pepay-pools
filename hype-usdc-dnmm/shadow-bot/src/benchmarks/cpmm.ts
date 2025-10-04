import {
  BenchmarkAdapter,
  BenchmarkQuoteSample,
  BenchmarkTickContext,
  BenchmarkTradeResult,
  OracleSnapshot,
  TradeIntent
} from '../types.js';

const BPS = 10_000n;
const WAD = 10n ** 18n;

export interface CpmmAdapterParams {
  readonly baseDecimals: number;
  readonly quoteDecimals: number;
  readonly baseReserves: bigint;
  readonly quoteReserves: bigint;
  readonly feeBps?: number;
}

export class CpmmBenchmarkAdapter implements BenchmarkAdapter {
  readonly id = 'cpmm' as const;

  private baseReserves: bigint;
  private quoteReserves: bigint;
  private readonly baseScale: bigint;
  private readonly quoteScale: bigint;
  private readonly feeBps: bigint;
  private currentMidWad: bigint;
  private currentSpreadBps = 0;
  private currentConfBps: number | undefined;
  private lastOracle?: OracleSnapshot;
  private readonly minBaseReserve: bigint;
  private readonly minQuoteReserve: bigint;

  constructor(private readonly params: CpmmAdapterParams) {
    this.baseReserves = params.baseReserves;
    this.quoteReserves = params.quoteReserves;
    this.baseScale = 10n ** BigInt(params.baseDecimals);
    this.quoteScale = 10n ** BigInt(params.quoteDecimals);
    this.feeBps = BigInt(params.feeBps ?? 30);
    this.currentMidWad = this.computeMidWad();
    this.minBaseReserve = clampMinReserve(params.baseReserves);
    this.minQuoteReserve = clampMinReserve(params.quoteReserves);
  }

  async init(): Promise<void> {
    // deterministic emulator – no external resources
  }

  async prepareTick(context: BenchmarkTickContext): Promise<void> {
    this.lastOracle = context.oracle;
    const mid = context.oracle.hc.midWad;
    if (mid && mid > 0n) {
      this.currentMidWad = mid;
    }
    this.currentSpreadBps = context.oracle.hc.spreadBps ?? this.currentSpreadBps;
    this.currentConfBps = context.oracle.pyth?.confBps;
  }

  async sampleQuote(side: 'base_in' | 'quote_in', sizeBaseWad: bigint): Promise<BenchmarkQuoteSample> {
    const preview = this.preview(side, sizeBaseWad);
    return {
      timestampMs: Date.now(),
      side,
      sizeBaseWad,
      feeBps: Number(this.feeBps),
      feeLvrBps: 0,
      rebateBps: 0,
      floorBps: 0,
      ttlMs: undefined,
      minOut: preview.success ? preview.amountOutWad : undefined,
      aomqFlags: undefined,
      mid: this.currentMidWad,
      spreadBps: this.currentSpreadBps,
      confBps: this.currentConfBps,
      aomqActive: false
    };
  }

  async simulateTrade(intent: TradeIntent): Promise<BenchmarkTradeResult> {
    const sizeWad = intent.side === 'base_in'
      ? toBaseWad(intent.amountIn, this.baseScale)
      : toQuoteWad(intent.amountIn, this.quoteScale);

    if (sizeWad <= 0n) {
      return this.buildRejection(intent, 'zero_trade');
    }

    const preview = this.preview(intent.side, sizeWad);
    if (!preview.success || preview.amountOutWad <= 0n) {
      return this.buildRejection(intent, preview.reason ?? 'insufficient_liquidity');
    }

    if (intent.minOut) {
      const minOutWad = intent.side === 'base_in'
        ? toQuoteWad(intent.minOut, this.quoteScale)
        : toBaseWad(intent.minOut, this.baseScale);
      if (preview.amountOutWad < minOutWad) {
        return this.buildRejection(intent, 'min_out_unmet');
      }
    }

    this.baseReserves = preview.nextBaseReserves;
    this.quoteReserves = preview.nextQuoteReserves;

    const midPrice = this.currentMidWad === 0n
      ? Number(preview.midWad) / Number(WAD)
      : Number(this.currentMidWad) / Number(WAD);
    const amountInQuote = intent.side === 'base_in'
      ? toDecimal(preview.executedBaseWad, this.baseScale) * midPrice
      : toDecimal(preview.executedIn, this.quoteScale);
    const amountOutQuote = intent.side === 'base_in'
      ? toDecimal(preview.amountOutWad, this.quoteScale)
      : toDecimal(preview.amountOutWad, this.baseScale) * midPrice;

    const pnlQuote = intent.side === 'base_in'
      ? amountOutQuote - amountInQuote
      : toDecimal(preview.executedIn, this.quoteScale) - amountOutQuote;

    const inventoryBase = this.baseReserves;
    const inventoryQuote = this.quoteReserves;

    return {
      intent,
      success: true,
      amountIn: preview.executedIn,
      amountOut: preview.amountOutWad,
      midUsed: this.currentMidWad,
      feeBpsUsed: Number(this.feeBps),
      feeLvrBps: 0,
      rebateBps: 0,
      feePaid: preview.feePaidWad,
      feeLvrPaid: 0n,
      rebatePaid: 0n,
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: false,
      minOut: preview.amountOutWad,
      slippageBpsVsMid: preview.slippageBps,
      pnlQuote,
      inventoryBase,
      inventoryQuote,
      latencyMs: preview.latencyMs,
      isPartial: preview.partial,
      appliedAmountIn: preview.executedIn,
      intentBaseSizeWad: intent.side === 'base_in' ? sizeWad : preview.amountOutWad,
      executedBaseSizeWad: preview.executedBaseWad
    };
  }

  private buildRejection(intent: TradeIntent, reason: string): BenchmarkTradeResult {
    return {
      intent,
      success: false,
      amountIn: 0n,
      amountOut: 0n,
      midUsed: this.currentMidWad,
      feeBpsUsed: Number(this.feeBps),
      feeLvrBps: 0,
      rebateBps: 0,
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: false,
      minOut: undefined,
      slippageBpsVsMid: 0,
      pnlQuote: 0,
      inventoryBase: this.baseReserves,
      inventoryQuote: this.quoteReserves,
      latencyMs: 5,
      rejectReason: reason,
      feePaid: 0n,
      feeLvrPaid: 0n,
      rebatePaid: 0n
    };
  }

  private preview(side: 'base_in' | 'quote_in', rawSize: bigint) {
    if (rawSize <= 0n) {
      return {
        success: false,
        amountOutWad: 0n,
        midWad: this.currentMidWad,
        spreadBps: this.currentSpreadBps,
        slippageBps: 0,
        latencyMs: 5,
        nextBaseReserves: this.baseReserves,
        nextQuoteReserves: this.quoteReserves,
        reason: 'zero_trade',
        executedIn: 0n,
        executedBaseWad: 0n,
        feePaidWad: 0n,
        partial: false
      } as const;
    }

    const feePaid = (rawSize * this.feeBps) / BPS;
    const feeAdjusted = rawSize - feePaid;
    if (feeAdjusted <= 0n) {
      return {
        success: false,
        amountOutWad: 0n,
        midWad: this.currentMidWad,
        spreadBps: this.currentSpreadBps,
        slippageBps: 0,
        latencyMs: 5,
        nextBaseReserves: this.baseReserves,
        nextQuoteReserves: this.quoteReserves,
        reason: 'fee_zero',
        executedIn: 0n,
        executedBaseWad: 0n,
        feePaidWad: feePaid,
        partial: false
      } as const;
    }

    if (side === 'base_in') {
      const k = this.baseReserves * this.quoteReserves;
      let targetQuote = this.quoteReserves;
      let partial = false;
      const tentativeNextBase = this.baseReserves + feeAdjusted;
      const tentativeNextQuote = tentativeNextBase === 0n ? this.quoteReserves : k / tentativeNextBase;
      if (tentativeNextQuote < this.minQuoteReserve) {
        targetQuote = this.minQuoteReserve;
        partial = true;
      } else {
        targetQuote = tentativeNextQuote;
      }
      const targetBase = targetQuote === 0n ? this.baseReserves : k / targetQuote;
      const executedIn = partial ? clampExecuted(rawSize, targetBase - this.baseReserves, this.feeBps) : rawSize;
      const feePaidWad = (executedIn * this.feeBps) / BPS;
      const effectiveIn = executedIn - feePaidWad;
      const nextBaseActual = this.baseReserves + effectiveIn;
      const nextQuoteActual = nextBaseActual === 0n ? this.quoteReserves : k / nextBaseActual;
      const amountOut = this.quoteReserves > nextQuoteActual ? this.quoteReserves - nextQuoteActual : 0n;
      const priceBefore = this.computeMidWad();
      const priceAfter = this.computeMidWad(nextBaseActual, nextQuoteActual);
      const slippage = computeSlippageBps(priceBefore, priceAfter);
      return {
        success: amountOut > 0n,
        amountOutWad: amountOut,
        midWad: this.currentMidWad,
        spreadBps: this.currentSpreadBps,
        slippageBps: slippage,
        latencyMs: 15,
        nextBaseReserves: nextBaseActual,
        nextQuoteReserves: nextQuoteActual,
        reason: amountOut > 0n ? undefined : 'zero_output',
        executedIn,
        executedBaseWad: executedIn,
        feePaidWad,
        partial
      } as const;
    }

    const k = this.baseReserves * this.quoteReserves;
    let targetBase = this.baseReserves;
    let partial = false;
    const tentativeNextQuote = this.quoteReserves + feeAdjusted;
    const tentativeNextBase = tentativeNextQuote === 0n ? this.baseReserves : k / tentativeNextQuote;
    if (tentativeNextBase < this.minBaseReserve) {
      targetBase = this.minBaseReserve;
      partial = true;
    } else {
      targetBase = tentativeNextBase;
    }
    const targetQuote = targetBase === 0n ? this.quoteReserves : k / targetBase;
    const executedIn = partial ? clampExecuted(rawSize, targetQuote - this.quoteReserves, this.feeBps) : rawSize;
    const feePaidWad = (executedIn * this.feeBps) / BPS;
    const effectiveIn = executedIn - feePaidWad;
    const nextQuoteActual = this.quoteReserves + effectiveIn;
    const nextBaseActual = nextQuoteActual === 0n ? this.baseReserves : k / nextQuoteActual;
    const amountOut = this.baseReserves > nextBaseActual ? this.baseReserves - nextBaseActual : 0n;
    const priceBefore = this.computeMidWad();
    const priceAfter = this.computeMidWad(nextBaseActual, nextQuoteActual);
    const slippage = computeSlippageBps(priceBefore, priceAfter);
    return {
      success: amountOut > 0n,
      amountOutWad: amountOut,
      midWad: this.currentMidWad,
      spreadBps: this.currentSpreadBps,
      slippageBps: slippage,
      latencyMs: 15,
      nextBaseReserves: nextBaseActual,
      nextQuoteReserves: nextQuoteActual,
      reason: amountOut > 0n ? undefined : 'zero_output',
      executedIn,
      executedBaseWad: amountOut,
      feePaidWad,
      partial
    } as const;
  }

  async close(): Promise<void> {
    // no external connections to release
  }

  private computeMidWad(base?: bigint, quote?: bigint): bigint {
    const baseRes = base ?? this.baseReserves;
    const quoteRes = quote ?? this.quoteReserves;
    if (baseRes === 0n) return 0n;
    const scaledQuote = quoteRes * this.baseScale;
    const price = scaledQuote / baseRes;
    return price * (WAD / this.quoteScale);
  }
}

function toBaseWad(amount: number, scale: bigint): bigint {
  return BigInt(Math.max(0, Math.round(amount * Number(scale))));
}

function toQuoteWad(amount: number, scale: bigint): bigint {
  return BigInt(Math.max(0, Math.round(amount * Number(scale))));
}

function toDecimal(value: bigint, scale: bigint): number {
  if (scale === 0n) return Number(value);
  return Number(value) / Number(scale);
}

function computeSlippageBps(midBefore: bigint, midAfter: bigint): number {
  if (midBefore === 0n) return 0;
  const before = Number(midBefore);
  const after = Number(midAfter);
  return ((after - before) / before) * 10_000;
}

function clampExecuted(rawSize: bigint, effectiveDelta: bigint, feeBps: bigint): bigint {
  if (effectiveDelta <= 0n) return rawSize;
  const denominator = BPS - feeBps;
  if (denominator <= 0n) return rawSize;
  const required = (effectiveDelta * BPS) / denominator;
  return required < rawSize ? required : rawSize;
}

function clampMinReserve(value: bigint): bigint {
  if (value <= 0n) return 1n;
  const floor = value / 20n;
  return floor > 0n ? floor : 1n;
}
