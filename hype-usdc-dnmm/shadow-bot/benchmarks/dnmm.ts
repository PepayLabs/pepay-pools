import {
  BenchmarkAdapter,
  BenchmarkQuoteSample,
  BenchmarkTradeResult,
  ChainRuntimeConfig,
  OracleReaderAdapter,
  PoolClientAdapter,
  TradeIntent
} from '../types.js';

const ORACLE_MODE_SPOT = 0;
const WAD = 10n ** 18n;
const BPS = 10_000n;

export interface DnmmAdapterParams {
  readonly chain: ChainRuntimeConfig;
  readonly poolClient: PoolClientAdapter;
  readonly oracleReader: OracleReaderAdapter;
}

export class DnmmBenchmarkAdapter implements BenchmarkAdapter {
  readonly id = 'dnmm' as const;

  private inventoryBase: bigint = 0n;
  private inventoryQuote: bigint = 0n;
  private baseScale!: bigint;
  private quoteScale!: bigint;

  constructor(private readonly params: DnmmAdapterParams) {}

  async init(): Promise<void> {
    const state = await this.params.poolClient.getState();
    this.inventoryBase = state.baseReserves;
    this.inventoryQuote = state.quoteReserves;
    this.baseScale = 10n ** BigInt(this.params.chain.baseDecimals);
    this.quoteScale = 10n ** BigInt(this.params.chain.quoteDecimals);
  }

  async close(): Promise<void> {
    // no-op
  }

  async sampleQuote(side: 'base_in' | 'quote_in', sizeBaseWad: bigint): Promise<BenchmarkQuoteSample> {
    const amount = side === 'base_in'
      ? sizeBaseWad
      : toQuoteWadFromBase(sizeBaseWad, this.currentMid(), this.baseScale, this.quoteScale);
    const raw = await this.params.poolClient.quoteExactIn(amount, side === 'base_in', ORACLE_MODE_SPOT, '0x');
    const mid = raw.midUsed ?? 0n;
    return {
      timestampMs: Date.now(),
      side,
      sizeBaseWad,
      feeBps: raw.feeBpsUsed ?? 0,
      mid,
      spreadBps: 0,
      confBps: 0,
      aomqActive: raw.reason === 'AOMQClamp'
    };
  }

  async simulateTrade(intent: TradeIntent): Promise<BenchmarkTradeResult> {
    const amountIn = intent.side === 'base_in'
      ? toScaled(intent.amountIn, this.baseScale)
      : toScaled(intent.amountIn, this.quoteScale);

    const response = await this.params.poolClient.quoteExactIn(amountIn, intent.side === 'base_in', ORACLE_MODE_SPOT, '0x');
    const amountOut = response.amountOut ?? 0n;
    const success = amountOut > 0n;
    const mid = response.midUsed ?? 0n;
    const execPrice = computeExecPrice(intent.side, amountIn, amountOut, this.baseScale, this.quoteScale);
    const midDecimal = mid === 0n ? Number(execPrice) : Number(mid) / Number(WAD);
    const slippage = computeSlippageBps(midDecimal, execPrice);

    if (intent.minOut) {
      const minOutWad = intent.side === 'base_in'
        ? toScaled(intent.minOut, this.quoteScale)
        : toScaled(intent.minOut, this.baseScale);
      if (amountOut < minOutWad) {
        return this.buildRejection(intent, mid);
      }
    }

    if (success) {
      if (intent.side === 'base_in') {
        this.inventoryBase += amountIn;
        this.inventoryQuote = this.inventoryQuote > amountOut ? this.inventoryQuote - amountOut : 0n;
      } else {
        this.inventoryQuote += amountIn;
        this.inventoryBase = this.inventoryBase > amountOut ? this.inventoryBase - amountOut : 0n;
      }
    }

    const pnlQuote = computePnlQuote(intent.side, intent.amountIn, amountOut, execPrice, this.baseScale, this.quoteScale);

    return {
      intent,
      success,
      amountIn,
      amountOut,
      midUsed: mid,
      feeBpsUsed: response.feeBpsUsed ?? 0,
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: response.reason === 'AOMQClamp',
      minOut: intent.minOut
        ? (intent.side === 'base_in'
            ? toScaled(intent.minOut, this.quoteScale)
            : toScaled(intent.minOut, this.baseScale))
        : undefined,
      slippageBpsVsMid: slippage,
      pnlQuote,
      inventoryBase: this.inventoryBase,
      inventoryQuote: this.inventoryQuote,
      latencyMs: 25,
      rejectReason: success ? undefined : response.reason
    };
  }

  private buildRejection(intent: TradeIntent, mid: bigint): BenchmarkTradeResult {
    return {
      intent,
      success: false,
      amountIn: 0n,
      amountOut: 0n,
      midUsed: mid,
      feeBpsUsed: 0,
      floorBps: 0,
      tiltBps: 0,
      aomqClamped: false,
      minOut: undefined,
      slippageBpsVsMid: 0,
      pnlQuote: 0,
      inventoryBase: this.inventoryBase,
      inventoryQuote: this.inventoryQuote,
      latencyMs: 20,
      rejectReason: 'min_out_unmet'
    };
  }

  private currentMid(): number {
    const base = Number(this.inventoryBase) / Number(this.baseScale);
    const quote = Number(this.inventoryQuote) / Number(this.quoteScale);
    if (base === 0) return 1;
    return quote / base;
  }
}

function toScaled(amount: number, scale: bigint): bigint {
  return BigInt(Math.max(0, Math.round(amount * Number(scale))));
}

function computeExecPrice(
  side: 'base_in' | 'quote_in',
  amountIn: bigint,
  amountOut: bigint,
  baseScale: bigint,
  quoteScale: bigint
): number {
  if (amountIn === 0n || amountOut === 0n) return 0;
  if (side === 'base_in') {
    const base = Number(amountIn) / Number(baseScale);
    const quote = Number(amountOut) / Number(quoteScale);
    return quote / base;
  }
  const quote = Number(amountIn) / Number(quoteScale);
  const base = Number(amountOut) / Number(baseScale);
  return quote / base;
}

function computeSlippageBps(mid: number, exec: number): number {
  if (mid === 0) return 0;
  return ((exec - mid) / mid) * 10_000;
}

function computePnlQuote(
  side: 'base_in' | 'quote_in',
  amountInNumber: number,
  amountOutWad: bigint,
  execPrice: number,
  baseScale: bigint,
  quoteScale: bigint
): number {
  if (side === 'base_in') {
    const amountOut = Number(amountOutWad) / Number(quoteScale);
    return amountOut - amountInNumber * execPrice;
  }
  const amountOutBase = Number(amountOutWad) / Number(baseScale);
  return amountInNumber - amountOutBase * execPrice;
}

function toQuoteWadFromBase(
  sizeBaseWad: bigint,
  mid: number,
  baseScale: bigint,
  quoteScale: bigint
): bigint {
  const baseAmount = Number(sizeBaseWad) / Number(baseScale);
  const quoteAmount = baseAmount * mid;
  return toScaled(quoteAmount, quoteScale);
}
