import {
  FeatureFlagsState,
  FeeConfigState,
  InventoryConfigState,
  MakerConfigState,
  OracleConfigState,
  PoolClientAdapter,
  PoolConfig,
  PoolState,
  PoolTokens,
  PreviewLadderSnapshot,
  RegimeFlag,
  RegimeFlags,
  REGIME_BIT_VALUES,
  QuotePreviewResult
} from '../types.js';

const DEFAULT_BASE_DECIMALS = 18;
const DEFAULT_QUOTE_DECIMALS = 6;
const BPS = 10_000n;

export interface SimPoolParams {
  readonly baseDecimals?: number;
  readonly quoteDecimals?: number;
  readonly baseReserves?: bigint;
  readonly quoteReserves?: bigint;
  readonly feeBps?: number;
}

export class SimPoolClient implements PoolClientAdapter {
  private readonly baseDecimals: number;
  private readonly quoteDecimals: number;
  private baseReserves: bigint;
  private quoteReserves: bigint;
  private readonly feeBps: number;

  constructor(params: SimPoolParams = {}) {
    this.baseDecimals = params.baseDecimals ?? DEFAULT_BASE_DECIMALS;
    this.quoteDecimals = params.quoteDecimals ?? DEFAULT_QUOTE_DECIMALS;
    const baseScale = 10n ** BigInt(this.baseDecimals);
    const quoteScale = 10n ** BigInt(this.quoteDecimals);
    this.baseReserves = params.baseReserves ?? 10_000n * baseScale;
    this.quoteReserves = params.quoteReserves ?? 10_000n * quoteScale;
    this.feeBps = params.feeBps ?? 30;
  }

  async getTokens(): Promise<PoolTokens> {
    return {
      base: '0xbase',
      quote: '0xquote',
      baseDecimals: this.baseDecimals,
      quoteDecimals: this.quoteDecimals,
      baseScale: 10n ** BigInt(this.baseDecimals),
      quoteScale: 10n ** BigInt(this.quoteDecimals)
    };
  }

  async getConfig(): Promise<PoolConfig> {
    const oracle: OracleConfigState = {
      maxAgeSec: 30,
      stallWindowSec: 5,
      confCapBpsSpot: 50,
      confCapBpsStrict: 100,
      divergenceBps: 200,
      allowEmaFallback: true,
      confWeightSpreadBps: 25,
      confWeightSigmaBps: 25,
      confWeightPythBps: 25,
      sigmaEwmaLambdaBps: 1,
      divergenceAcceptBps: 50,
      divergenceSoftBps: 75,
      divergenceHardBps: 100,
      haircutMinBps: 10,
      haircutSlopeBps: 5
    };
    const inventory: InventoryConfigState = {
      targetBaseXstar: this.baseReserves,
      floorBps: 50,
      recenterThresholdPct: 5,
      invTiltBpsPer1pct: 100,
      invTiltMaxBps: 200,
      tiltConfWeightBps: 100,
      tiltSpreadWeightBps: 100
    };
    const fee: FeeConfigState = {
      baseBps: this.feeBps,
      alphaNumerator: 1,
      alphaDenominator: 1,
      betaInvDevNumerator: 1,
      betaInvDevDenominator: 1,
      capBps: 250,
      decayPctPerBlock: 0,
      gammaSizeLinBps: 0,
      gammaSizeQuadBps: 0,
      sizeFeeCapBps: 0
    };
    const maker: MakerConfigState = {
      s0Notional: this.quoteReserves,
      ttlMs: 1_000,
      alphaBboBps: 100,
      betaFloorBps: 50
    };
    const featureFlags: FeatureFlagsState = {
      blendOn: true,
      parityCiOn: true,
      debugEmit: false,
      enableSoftDivergence: true,
      enableSizeFee: true,
      enableBboFloor: true,
      enableInvTilt: true,
      enableAOMQ: true,
      enableRebates: false,
      enableAutoRecenter: true
    };
    return { oracle, inventory, fee, maker, featureFlags };
  }

  async getState(): Promise<PoolState> {
    return {
      baseReserves: this.baseReserves,
      quoteReserves: this.quoteReserves,
      lastMidWad: this.computeMidWad(),
      snapshotAgeSec: 0,
      snapshotTimestamp: Math.floor(Date.now() / 1_000)
    };
  }

  async getPreviewLadder(): Promise<PreviewLadderSnapshot> {
    return {
      rows: [],
      snapshotTimestamp: Math.floor(Date.now() / 1_000),
      snapshotMidWad: this.computeMidWad()
    };
  }

  async previewFees(): Promise<{ ask: number[]; bid: number[] }> {
    return { ask: [this.feeBps], bid: [this.feeBps] };
  }

  async quoteExactIn(amountIn: bigint, isBaseIn: boolean, _oracleMode?: number, _oracleData?: string): Promise<QuotePreviewResult> {
    const fee = (amountIn * BigInt(this.feeBps)) / BPS;
    const netIn = amountIn - fee;
    if (netIn <= 0n) {
      return {
        amountOut: 0n,
        midUsed: this.computeMidWad(),
        feeBpsUsed: this.feeBps,
        partialFillAmountIn: 0n,
        usedFallback: false,
        reason: 'fee'
      };
    }
    if (isBaseIn) {
      const k = this.baseReserves * this.quoteReserves;
      const newBase = this.baseReserves + netIn;
      const newQuote = k / newBase;
      const amountOut = this.quoteReserves - newQuote;
      return this.finishQuote(isBaseIn, amountIn, amountOut, newBase, newQuote);
    }
    const k = this.baseReserves * this.quoteReserves;
    const newQuote = this.quoteReserves + netIn;
    const newBase = k / newQuote;
    const amountOut = this.baseReserves - newBase;
    return this.finishQuote(isBaseIn, amountIn, amountOut, newBase, newQuote);
  }

  computeRegimeFlags(): RegimeFlags {
    return { bitmask: 0, asArray: [] };
  }

  computeGuaranteedMinOutBps(): number {
    return 25;
  }

  private finishQuote(
    isBaseIn: boolean,
    amountIn: bigint,
    amountOut: bigint,
    nextBase: bigint,
    nextQuote: bigint
  ): QuotePreviewResult {
    this.baseReserves = nextBase;
    this.quoteReserves = nextQuote;
    return {
      amountOut,
      midUsed: this.computeMidWad(),
      feeBpsUsed: this.feeBps,
      partialFillAmountIn: amountIn,
      usedFallback: false,
      reason: 'OK'
    };
  }

  private computeMidWad(): bigint {
    const base = Number(this.baseReserves) / Number(10n ** BigInt(this.baseDecimals));
    const quote = Number(this.quoteReserves) / Number(10n ** BigInt(this.quoteDecimals));
    if (base === 0) return 0n;
    const price = quote / base;
    return BigInt(Math.round(price * 1_000_000_000_000_000_000));
  }
}
