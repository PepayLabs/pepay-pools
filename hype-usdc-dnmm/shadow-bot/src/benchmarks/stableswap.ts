import {
  BenchmarkAdapter,
  BenchmarkQuoteSample,
  BenchmarkTickContext,
  BenchmarkTradeResult,
  OracleSnapshot,
  TradeIntent
} from '../types.js';

const BPS = 10_000;
const WAD = 10n ** 18n;

export interface StableSwapParams {
  readonly baseDecimals: number;
  readonly quoteDecimals: number;
  readonly baseReserves: bigint;
  readonly quoteReserves: bigint;
  readonly amplification?: number;
  readonly feeBps?: number;
}

export class StableSwapBenchmarkAdapter implements BenchmarkAdapter {
  readonly id = 'stableswap' as const;

  private baseReserves: number;
  private quoteReserves: number;
  private readonly baseScale: bigint;
  private readonly quoteScale: bigint;
  private readonly amplification: number;
  private readonly feeBps: number;
  private currentMidWad: bigint;
  private currentSpreadBps = 0;
  private currentConfBps: number | undefined;
  private lastOracle?: OracleSnapshot;

  constructor(private readonly params: StableSwapParams) {
    this.baseScale = 10n ** BigInt(params.baseDecimals);
    this.quoteScale = 10n ** BigInt(params.quoteDecimals);
    this.baseReserves = toDecimal(params.baseReserves, this.baseScale);
    this.quoteReserves = toDecimal(params.quoteReserves, this.quoteScale);
    this.amplification = params.amplification ?? 100;
    this.feeBps = params.feeBps ?? 4;
    this.currentMidWad = toMidWad(this.currentMid());
  }

  async init(): Promise<void> {
    // no-op
  }

  async close(): Promise<void> {
    // no-op
  }

  async prepareTick(context: BenchmarkTickContext): Promise<void> {
    this.lastOracle = context.oracle;
    if (context.oracle.hc.midWad && context.oracle.hc.midWad > 0n) {
      const mid = Number(context.oracle.hc.midWad) / Number(WAD);
      this.adjustReservesToMid(mid);
      this.currentMidWad = context.oracle.hc.midWad;
    } else {
      this.currentMidWad = toMidWad(this.currentMid());
    }
    this.currentSpreadBps = context.oracle.hc.spreadBps ?? this.currentSpreadBps;
    this.currentConfBps = context.oracle.pyth?.confBps;
  }

  async sampleQuote(side: 'base_in' | 'quote_in', sizeBaseWad: bigint): Promise<BenchmarkQuoteSample> {
    const size = Number(sizeBaseWad) / Number(this.baseScale);
    const preview = this.preview(side, size, false);
    return {
      timestampMs: Date.now(),
      side,
      sizeBaseWad,
      feeBps: this.feeBps,
      mid: this.currentMidWad,
      spreadBps: this.currentSpreadBps,
      confBps: this.currentConfBps,
      aomqActive: false
    };
  }

  async simulateTrade(intent: TradeIntent): Promise<BenchmarkTradeResult> {
    const size = intent.side === 'base_in'
      ? intent.amountIn
      : intent.amountIn / this.currentMid();

    if (!Number.isFinite(size) || size <= 0) {
      return this.buildRejection(intent, 'zero_trade');
    }

    const preview = this.preview(intent.side, size, true);
    if (!preview.success || preview.amountOut <= 0) {
      return this.buildRejection(intent, preview.reason ?? 'insufficient_liquidity');
    }

    const amountOutWad = intent.side === 'base_in'
      ? toBigInt(preview.amountOut, this.quoteScale)
      : toBigInt(preview.amountOut, this.baseScale);

    const amountInWad = intent.side === 'base_in'
      ? toBigInt(size, this.baseScale)
      : toBigInt(intent.amountIn, this.quoteScale);

    if (intent.minOut) {
      const minOutWad = intent.side === 'base_in'
        ? toBigInt(intent.minOut, this.quoteScale)
        : toBigInt(intent.minOut, this.baseScale);
      if (amountOutWad < minOutWad) {
        return this.buildRejection(intent, 'min_out_unmet');
      }
    }

    this.baseReserves = preview.nextBaseReserves;
    this.quoteReserves = preview.nextQuoteReserves;

    const pnlQuote = intent.side === 'base_in'
      ? preview.amountOut - size * preview.mid
      : intent.amountIn - preview.amountOut * preview.mid;

    return {
      intent,
      success: true,
      amountIn: amountInWad,
      amountOut: amountOutWad,
      midUsed: this.currentMidWad,
      feeBpsUsed: this.feeBps,
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: false,
      minOut: undefined,
      slippageBpsVsMid: preview.slippageBps,
      pnlQuote,
      inventoryBase: toBigInt(this.baseReserves, this.baseScale),
      inventoryQuote: toBigInt(this.quoteReserves, this.quoteScale),
      latencyMs: 12
    };
  }

  private buildRejection(intent: TradeIntent, reason: string): BenchmarkTradeResult {
    return {
      intent,
      success: false,
      amountIn: 0n,
      amountOut: 0n,
      midUsed: this.currentMidWad,
      feeBpsUsed: this.feeBps,
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: false,
      minOut: undefined,
      slippageBpsVsMid: 0,
      pnlQuote: 0,
      inventoryBase: toBigInt(this.baseReserves, this.baseScale),
      inventoryQuote: toBigInt(this.quoteReserves, this.quoteScale),
      latencyMs: 5,
      rejectReason: reason
    };
  }

  private preview(side: 'base_in' | 'quote_in', size: number, apply: boolean) {
    const amp = this.amplification;
    const x = this.baseReserves;
    const y = this.quoteReserves;
    const dx = side === 'base_in' ? size : size / this.currentMid();
    const feeMultiplier = 1 - this.feeBps / BPS;
    const dxAfterFee = dx * feeMultiplier;

    if (dxAfterFee <= 0) {
      return {
        success: false,
        amountOut: 0,
        mid: this.currentMid(),
        midWad: this.currentMidWad,
        spreadBps: this.currentSpreadBps,
        slippageBps: 0,
        nextBaseReserves: x,
        nextQuoteReserves: y,
        reason: 'fee_zero'
      } as const;
    }

    if (side === 'base_in') {
      const D = computeD(amp, x, y);
      const newX = x + dxAfterFee;
      const newY = getY(amp, newX, D);
      const amountOut = Math.max(0, y - newY);
      const nextBase = apply ? newX : x;
      const nextQuote = apply ? newY : y;
      const midBefore = this.currentMid();
      const midAfter = nextQuote === 0 ? midBefore : nextQuote / nextBase;
      return {
        success: amountOut > 0,
        amountOut,
        mid: midBefore,
        midWad: this.currentMidWad,
        spreadBps: this.currentSpreadBps,
        slippageBps: computeSlippageBps(midBefore, midAfter),
        nextBaseReserves: nextBase,
        nextQuoteReserves: nextQuote,
        reason: amountOut > 0 ? undefined : 'zero_output'
      } as const;
    }

    const D = computeD(amp, x, y);
    const newY = y + dxAfterFee;
    const newX = getY(amp, newY, D);
    const amountOut = Math.max(0, x - newX);
    const nextBase = apply ? newX : x;
    const nextQuote = apply ? newY : y;
    const midBefore = this.currentMid();
    const midAfter = nextQuote === 0 ? midBefore : nextQuote / nextBase;
    return {
      success: amountOut > 0,
      amountOut,
      mid: midBefore,
      midWad: this.currentMidWad,
      spreadBps: this.currentSpreadBps,
      slippageBps: computeSlippageBps(midBefore, midAfter),
      nextBaseReserves: nextBase,
      nextQuoteReserves: nextQuote,
      reason: amountOut > 0 ? undefined : 'zero_output'
    } as const;
  }

  private currentMid(): number {
    if (this.baseReserves === 0) return 0;
    return this.quoteReserves / this.baseReserves;
  }

  private adjustReservesToMid(targetMid: number): void {
    if (!Number.isFinite(targetMid) || targetMid <= 0) {
      this.currentMidWad = toMidWad(this.currentMid());
      return;
    }
    const liquidity = Math.sqrt(this.baseReserves * this.quoteReserves);
    const newBase = liquidity / Math.sqrt(targetMid);
    const newQuote = liquidity * Math.sqrt(targetMid);
    if (Number.isFinite(newBase) && Number.isFinite(newQuote) && newBase > 0 && newQuote > 0) {
      this.baseReserves = newBase;
      this.quoteReserves = newQuote;
    }
    this.currentMidWad = toMidWad(this.currentMid());
  }
}

function computeD(amp: number, x: number, y: number): number {
  const n = 2;
  const S = x + y;
  if (S === 0 || x === 0 || y === 0) return 0;
  let D = S;
  const Ann = amp * n;
  for (let i = 0; i < 32; i += 1) {
    const Dp = (D * D) / (x * n) / (y * n);
    const prevD = D;
    D = ((Ann * S + Dp * n) * D) / ((Ann - 1) * D + (n + 1) * Dp);
    if (Math.abs(D - prevD) <= 1e-12) break;
  }
  return D;
}

function getY(amp: number, x: number, D: number): number {
  const n = 2;
  const Ann = amp * n;
  if (x === 0) return 0;
  const c = (D * D * D) / (x * n * n * Ann);
  const b = x + D / Ann;
  let y = D;
  for (let i = 0; i < 32; i += 1) {
    const yPrev = y;
    y = (y * y + c) / (2 * y + b - D);
    if (Math.abs(y - yPrev) <= 1e-12) break;
  }
  return y;
}

function toDecimal(value: bigint, scale: bigint): number {
  if (scale === 0n) return Number(value);
  return Number(value) / Number(scale);
}

function toBigInt(value: number, scale: bigint): bigint {
  const scaled = value * Number(scale);
  if (!Number.isFinite(scaled) || scaled <= 0) return 0n;
  return BigInt(Math.round(scaled));
}

function toMidWad(mid: number): bigint {
  return BigInt(Math.round(mid * Number(WAD)));
}

function computeSlippageBps(before: number, after: number): number {
  if (before === 0) return 0;
  return ((after - before) / before) * 10_000;
}
