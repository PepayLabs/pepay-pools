import {
  BenchmarkAdapter,
  BenchmarkQuoteSample,
  BenchmarkTickContext,
  BenchmarkTradeResult,
  ChainRuntimeConfig,
  OracleReaderAdapter,
  OracleSnapshot,
  PoolClientAdapter,
  PoolConfig,
  PoolState,
  RegimeFlag,
  RegimeFlags,
  RunSettingDefinition,
  ShadowBotConfig,
  ShadowBotParameters,
  TradeIntent
} from '../types.js';

const ORACLE_MODE_SPOT = 0;
const WAD = 10n ** 18n;
const BPS = 10_000n;

interface QuoteComputation {
  readonly side: 'base_in' | 'quote_in';
  readonly amountIn: bigint;
  readonly executedAmountIn: bigint;
  readonly amountOut: bigint;
  readonly feeBps: number;
  readonly midWad: bigint;
  readonly regimeFlags: RegimeFlags;
  readonly minOutBps: number;
  readonly reason: string;
  readonly usedFallback: boolean;
  readonly aomqUsed: boolean;
  readonly sigmaBps: number;
}

export interface DnmmAdapterParams {
  readonly chain: ChainRuntimeConfig;
  readonly poolClient: PoolClientAdapter;
  readonly oracleReader: OracleReaderAdapter;
  readonly setting: RunSettingDefinition;
  readonly baseConfig: ShadowBotConfig;
}

export class DnmmBenchmarkAdapter implements BenchmarkAdapter {
  readonly id = 'dnmm' as const;

  private inventoryBase: bigint = 0n;
  private inventoryQuote: bigint = 0n;
  private baseScale!: bigint;
  private quoteScale!: bigint;
  private lastOracle?: OracleSnapshot;
  private lastPoolState?: PoolState;
  private lastRegimeFlags?: RegimeFlags;
  private currentMidWad: bigint = 0n;
  private currentSpreadBps = 0;
  private currentConfBps?: number;
  private poolConfig?: PoolConfig;
  private readonly parameters: ShadowBotParameters;
  private readonly setting: RunSettingDefinition;
  private readonly makerTtlMs: number;
  private readonly feeLvrBps: number;
  private readonly rebateBps: number;
  private readonly enableAomq: boolean;
  private readonly enableRebates: boolean;
  private readonly enableLvrFee: boolean;

  constructor(private readonly params: DnmmAdapterParams) {
    this.setting = params.setting;
    this.parameters = params.baseConfig.parameters;
    this.enableAomq = this.setting.featureFlags.enableAOMQ;
    this.enableRebates = this.setting.featureFlags.enableRebates;
    this.enableLvrFee = this.setting.featureFlags.enableLvrFee;
    const baseKappa = this.parameters.fee.kappaLvrBps ?? 0;
    const overrideKappa = this.setting.fee?.kappaLvrBps;
    const kappaCandidate = overrideKappa ?? baseKappa;
    this.feeLvrBps = this.enableLvrFee ? kappaCandidate : 0;
    const baseRebateBps = 3;
    const overrideRebate = this.setting.rebates?.bps;
    this.rebateBps = this.enableRebates ? overrideRebate ?? baseRebateBps : 0;
    this.makerTtlMs = this.setting.makerParams.ttlMs ?? this.parameters.maker.ttlMs;
  }

  async init(): Promise<void> {
    const tokens = await this.params.poolClient.getTokens();
    this.baseScale = tokens.baseScale;
    this.quoteScale = tokens.quoteScale;
    this.poolConfig = await this.params.poolClient.getConfig();
    const state = await this.params.poolClient.getState();
    this.inventoryBase = state.baseReserves;
    this.inventoryQuote = state.quoteReserves;
    this.lastPoolState = state;
    this.currentMidWad = state.lastMidWad ?? 0n;
  }

  async close(): Promise<void> {
    // adapters do not hold external resources currently
  }

  async prepareTick(context: BenchmarkTickContext): Promise<void> {
    this.lastOracle = context.oracle;
    this.lastPoolState = context.poolState;
    this.inventoryBase = context.poolState.baseReserves;
    this.inventoryQuote = context.poolState.quoteReserves;
    if (context.oracle.hc.midWad && context.oracle.hc.midWad > 0n) {
      this.currentMidWad = context.oracle.hc.midWad;
    }
    this.currentSpreadBps = context.oracle.hc.spreadBps ?? this.currentSpreadBps;
    this.currentConfBps = context.oracle.pyth?.confBps;
  }

  async sampleQuote(side: 'base_in' | 'quote_in', sizeBaseWad: bigint): Promise<BenchmarkQuoteSample> {
    const preview = await this.evaluateQuote(side, sizeBaseWad);
    return {
      timestampMs: Date.now(),
      side,
      sizeBaseWad,
      feeBps: preview.feeBps,
      feeLvrBps: this.feeLvrBps,
      rebateBps: this.rebateBps,
      floorBps: this.poolConfig?.inventory.floorBps,
      ttlMs: this.makerTtlMs,
      latencyMs: this.setting.latency.quoteToTxMs,
      minOut: BigInt(preview.minOutBps),
      aomqFlags: preview.aomqUsed ? 'AOMQ' : undefined,
      mid: preview.midWad,
      spreadBps: this.currentSpreadBps,
      confBps: this.currentConfBps,
      aomqActive: preview.aomqUsed
    };
  }

  async simulateTrade(intent: TradeIntent): Promise<BenchmarkTradeResult> {
    const amountInWad = intent.side === 'base_in'
      ? toScaled(intent.amountIn, this.baseScale)
      : toScaled(intent.amountIn, this.quoteScale);
    const baseSizeWad = intent.side === 'base_in'
      ? amountInWad
      : toBaseWadFromQuote(amountInWad, this.currentMid(), this.baseScale, this.quoteScale);
    const preview = await this.evaluateQuote(intent.side, baseSizeWad, amountInWad);
    const amountIn = preview.amountIn;
    const executedIn = preview.executedAmountIn;
    const amountOut = preview.amountOut;
    const success = amountOut > 0n && preview.reason.toLowerCase() !== 'rejected';

    if (success) {
      if (intent.side === 'base_in') {
        this.inventoryBase += executedIn;
        this.inventoryQuote = this.inventoryQuote > amountOut ? this.inventoryQuote - amountOut : 0n;
      } else {
        this.inventoryQuote += executedIn;
        this.inventoryBase = this.inventoryBase > amountOut ? this.inventoryBase - amountOut : 0n;
      }
    }

    const execPrice = computeExecPrice(intent.side, executedIn, amountOut, this.baseScale, this.quoteScale);
    const midDecimal = preview.midWad === 0n ? execPrice : Number(preview.midWad) / Number(WAD);
    const slippage = computeSlippageBps(midDecimal, execPrice);
    const pnlQuote = computePnlQuote(intent.side, intent.amountIn, amountOut, execPrice, this.baseScale, this.quoteScale);

    const feePaid = (executedIn * BigInt(preview.feeBps)) / BPS;
    const feeLvrPaid = this.feeLvrBps > 0 ? (executedIn * BigInt(this.feeLvrBps)) / BPS : 0n;
    const rebatePaid = this.rebateBps > 0 ? (executedIn * BigInt(this.rebateBps)) / BPS : 0n;
    const isPartial = executedIn < amountIn;
    const executedBaseWad = intent.side === 'base_in'
      ? executedIn
      : toBaseWadFromQuote(executedIn, this.currentMid(), this.baseScale, this.quoteScale);

    this.lastRegimeFlags = preview.regimeFlags;
    this.currentMidWad = preview.midWad;

    return {
      intent,
      success,
      amountIn,
      amountOut,
      midUsed: preview.midWad,
      feeBpsUsed: preview.feeBps,
      feeLvrBps: this.feeLvrBps,
      rebateBps: this.rebateBps,
      feePaid,
      feeLvrPaid,
      rebatePaid,
      floorBps: this.poolConfig?.inventory.floorBps,
      tiltBps: 0,
      aomqClamped: preview.regimeFlags.asArray.includes('AOMQ'),
      floorEnforced: preview.regimeFlags.asArray.includes('NearFloor'),
      aomqUsed: preview.aomqUsed,
      minOut: BigInt(preview.minOutBps),
      slippageBpsVsMid: slippage,
      pnlQuote,
      inventoryBase: this.inventoryBase,
      inventoryQuote: this.inventoryQuote,
      latencyMs: this.setting.latency.quoteToTxMs,
      rejectReason: success ? undefined : preview.reason,
      isPartial,
      appliedAmountIn: executedIn,
      timestampMs: intent.timestampMs,
      intentBaseSizeWad: baseSizeWad,
      executedBaseSizeWad: executedBaseWad,
      sigmaBps: preview.sigmaBps
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
      latencyMs: this.setting.latency.quoteToTxMs,
      rejectReason: 'min_out_unmet'
    };
  }

  private currentMid(): number {
    if (this.currentMidWad > 0n) {
      return Number(this.currentMidWad) / Number(WAD);
    }
    if (this.lastOracle?.hc.midWad !== undefined && this.lastOracle.hc.midWad > 0n) {
      return Number(this.lastOracle.hc.midWad) / Number(WAD);
    }
    const base = Number(this.inventoryBase) / Number(this.baseScale);
    const quote = Number(this.inventoryQuote) / Number(this.quoteScale);
    if (base === 0) return 1;
    return quote / base;
  }

  private async evaluateQuote(
    side: 'base_in' | 'quote_in',
    sizeBaseWad: bigint,
    amountInOverride?: bigint
  ): Promise<QuoteComputation> {
    const mid = this.currentMid();
    const amountIn = amountInOverride ?? (side === 'base_in'
      ? sizeBaseWad
      : toQuoteWadFromBase(sizeBaseWad, mid, this.baseScale, this.quoteScale));

    const response = await this.params.poolClient.quoteExactIn(amountIn, side === 'base_in', ORACLE_MODE_SPOT, '0x');
    const executedIn = response.partialFillAmountIn && BigInt(response.partialFillAmountIn) > 0n
      ? BigInt(response.partialFillAmountIn)
      : BigInt(amountIn);
    const poolState = this.lastPoolState ?? (await this.params.poolClient.getState());
    const poolConfig = this.poolConfig ?? (await this.params.poolClient.getConfig());
    const clampFlags: RegimeFlag[] = [];
    if (response.reason === 'AOMQClamp' && this.enableAomq) {
      clampFlags.push('AOMQ');
    }
    const regimeFlags = this.params.poolClient.computeRegimeFlags({
      poolState,
      config: poolConfig,
      usedFallback: Boolean(response.usedFallback),
      clampFlags
    });
    const minOutBps = this.params.poolClient.computeGuaranteedMinOutBps(regimeFlags);
    const midWad = response.midUsed && response.midUsed > 0n ? BigInt(response.midUsed) : this.currentMidWad;

    return {
      side,
      amountIn: BigInt(amountIn),
      executedAmountIn: executedIn,
      amountOut: BigInt(response.amountOut ?? 0n),
      feeBps: Number(response.feeBpsUsed ?? 0),
      midWad,
      regimeFlags,
      minOutBps,
      reason: String(response.reason ?? 'OK'),
      usedFallback: Boolean(response.usedFallback),
      aomqUsed: this.enableAomq && regimeFlags.asArray.includes('AOMQ'),
      sigmaBps: poolState.sigmaBps ?? 0
    };
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

function toBaseWadFromQuote(
  quoteWad: bigint,
  mid: number,
  baseScale: bigint,
  quoteScale: bigint
): bigint {
  if (mid <= 0) return 0n;
  const quoteAmount = Number(quoteWad) / Number(quoteScale);
  const baseAmount = quoteAmount / mid;
  return toScaled(baseAmount, baseScale);
}
