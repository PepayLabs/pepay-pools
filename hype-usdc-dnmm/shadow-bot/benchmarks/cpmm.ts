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

  constructor(private readonly params: CpmmAdapterParams) {
    this.baseReserves = params.baseReserves;
    this.quoteReserves = params.quoteReserves;
    this.baseScale = 10n ** BigInt(params.baseDecimals);
    this.quoteScale = 10n ** BigInt(params.quoteDecimals);
    this.feeBps = BigInt(params.feeBps ?? 30);
    this.currentMidWad = this.computeMidWad();
  }

  async init(): Promise<void> {
    // no-op for deterministic emulator
  }

  async close(): Promise<void> {
    // no-op
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
    const snapshot = this.preview(side, sizeBaseWad, false);
    return {
      timestampMs: Date.now(),
      side,
      sizeBaseWad,
      feeBps: Number(this.feeBps),
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

    const preview = this.preview(intent.side, sizeWad, true);
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

    const midPrice = this.currentMidWad === 0n ? Number(preview.midWad) / Number(WAD) : Number(this.currentMidWad) / Number(WAD);
    const amountInQuote = intent.side === 'base_in'
      ? intent.amountIn * midPrice
      : intent.amountIn;
    const amountOutQuote = intent.side === 'base_in'
      ? toDecimal(preview.amountOutWad, this.quoteScale)
      : toDecimal(preview.amountOutWad, this.baseScale) * midPrice;

    const pnlQuote = intent.side === 'base_in'
      ? amountOutQuote - amountInQuote
      : intent.amountIn - amountOutQuote;

    const inventoryBase = this.baseReserves;
    const inventoryQuote = this.quoteReserves;

    return {
      intent,
      success: true,
      amountIn: sizeWad,
      amountOut: preview.amountOutWad,
      midUsed: this.currentMidWad,
      feeBpsUsed: Number(this.feeBps),
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: false,
      minOut: undefined,
      slippageBpsVsMid: preview.slippageBps,
      pnlQuote,
      inventoryBase,
      inventoryQuote,
      latencyMs: preview.latencyMs
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
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: false,
      minOut: undefined,
      slippageBpsVsMid: 0,
      pnlQuote: 0,
      inventoryBase: this.baseReserves,
      inventoryQuote: this.quoteReserves,
      latencyMs: 5,
      rejectReason: reason
    };
  }

  private preview(side: 'base_in' | 'quote_in', rawSize: bigint, apply: boolean) {
    const feeAdjusted = rawSize - (rawSize * this.feeBps) / BPS;
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
        reason: 'fee_zero'
      } as const;
    }

    if (side === 'base_in') {
      const k = this.baseReserves * this.quoteReserves;
      const nextBase = this.baseReserves + feeAdjusted;
      const nextQuote = nextBase === 0n ? this.quoteReserves : k / nextBase;
      const amountOut = this.quoteReserves - nextQuote;
      const priceBefore = this.computeMidWad();
      const priceAfter = this.computeMidWad(nextBase, nextQuote);
      const slippage = computeSlippageBps(priceBefore, priceAfter);
      if (apply) {
        this.baseReserves = nextBase;
        this.quoteReserves = nextQuote;
      }
      return {
        success: amountOut > 0n,
        amountOutWad: amountOut,
        midWad: this.currentMidWad,
        spreadBps: this.currentSpreadBps,
        slippageBps: slippage,
        latencyMs: 15,
        nextBaseReserves: nextBase,
        nextQuoteReserves: nextQuote,
        reason: amountOut > 0n ? undefined : 'zero_output'
      } as const;
    }

    // quote_in path
    const k = this.baseReserves * this.quoteReserves;
    const nextQuote = this.quoteReserves + feeAdjusted;
    const nextBase = nextQuote === 0n ? this.baseReserves : k / nextQuote;
    const amountOut = this.baseReserves - nextBase;
    const priceBefore = this.computeMidWad();
    const priceAfter = this.computeMidWad(nextBase, nextQuote);
    const slippage = computeSlippageBps(priceBefore, priceAfter);
    if (apply) {
      this.baseReserves = nextBase;
      this.quoteReserves = nextQuote;
    }
    return {
      success: amountOut > 0n,
      amountOutWad: amountOut,
      midWad: this.currentMidWad,
      spreadBps: this.currentSpreadBps,
      slippageBps: slippage,
      latencyMs: 15,
      nextBaseReserves: nextBase,
      nextQuoteReserves: nextQuote,
      reason: amountOut > 0n ? undefined : 'zero_output'
    } as const;
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
