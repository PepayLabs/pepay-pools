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
  QuotePreviewResult,
  RegimeFlag,
  RegimeFlags,
  REGIME_BIT_VALUES
} from '../types.js';
import { ScenarioEngine } from './scenarios.js';
import { MockClock } from './mockClock.js';
import { ScenarioParams } from './types.js';

const WAD = 10n ** 18n;
const BPS = 10_000n;

function toWad(value: number): bigint {
  return BigInt(Math.round(value * Number(WAD)));
}

function applyBps(value: bigint, bps: number): bigint {
  return (value * (BPS + BigInt(Math.round(bps)))) / BPS;
}

function clampBps(value: number, min = 0, max = 500): number {
  return Math.min(Math.max(value, min), max);
}

function buildFeatureFlags(params: ScenarioParams): FeatureFlagsState {
  return {
    blendOn: true,
    parityCiOn: true,
    debugEmit: false,
    enableSoftDivergence: true,
    enableSizeFee: true,
    enableBboFloor: true,
    enableInvTilt: true,
    enableAOMQ: true,
    enableRebates: false,
    enableAutoRecenter: Boolean(params.rebalance_jump)
  };
}

function defaultOracleConfig(): OracleConfigState {
  return {
    maxAgeSec: 30,
    stallWindowSec: 5,
    confCapBpsSpot: 250,
    confCapBpsStrict: 150,
    divergenceBps: 80,
    allowEmaFallback: true,
    confWeightSpreadBps: 20,
    confWeightSigmaBps: 10,
    confWeightPythBps: 30,
    sigmaEwmaLambdaBps: 5000,
    divergenceAcceptBps: 35,
    divergenceSoftBps: 50,
    divergenceHardBps: 85,
    haircutMinBps: 5,
    haircutSlopeBps: 15
  };
}

function defaultInventoryConfig(baseScale: bigint): InventoryConfigState {
  return {
    targetBaseXstar: 2500n * baseScale,
    floorBps: 500,
    recenterThresholdPct: 5,
    invTiltBpsPer1pct: 8,
    invTiltMaxBps: 40,
    tiltConfWeightBps: 20,
    tiltSpreadWeightBps: 20
  };
}

function defaultFeeConfig(): FeeConfigState {
  return {
    baseBps: 10,
    alphaNumerator: 1,
    alphaDenominator: 2,
    betaInvDevNumerator: 3,
    betaInvDevDenominator: 4,
    capBps: 200,
    decayPctPerBlock: 1,
    gammaSizeLinBps: 12,
    gammaSizeQuadBps: 3,
    sizeFeeCapBps: 80
  };
}

function defaultMakerConfig(quoteScale: bigint): MakerConfigState {
  return {
    s0Notional: 500_000n * quoteScale,
    ttlMs: 3000,
    alphaBboBps: 15,
    betaFloorBps: 10
  };
}

function computeBaseReserves(target: bigint, params: ScenarioParams): bigint {
  if (!params.inventory_dev_pct) return target;
  const adjustment = (target * BigInt(params.inventory_dev_pct)) / 100n;
  return target > adjustment ? target - adjustment : target;
}

function computeQuoteReserves(base: bigint, midWad: bigint, quoteScale: bigint): bigint {
  return (base * midWad) / WAD / (WAD / quoteScale);
}

function computeFeeBps(params: ScenarioParams, sizeRatioBps: number): number {
  const baseFee = 10;
  const deltaContribution = Math.max(0, Math.round(params.delta_bps / 4));
  const confContribution = Math.max(0, Math.round((params.conf_bps - 20) / 6));
  const spreadContribution = Math.max(0, Math.round(params.spread_bps / 3));
  const inventoryContribution = params.inventory_dev_pct ? Math.round(params.inventory_dev_pct) : 0;
  const sizeContribution = Math.round(sizeRatioBps / 50);
  const emergency = params.aomq ? 40 : 0;
  return clampBps(baseFee + deltaContribution + confContribution + spreadContribution + inventoryContribution + sizeContribution + emergency);
}

export class MockPoolClient implements PoolClientAdapter {
  private readonly tokens: PoolTokens;
  private readonly config: PoolConfig;
  private lastParams: ScenarioParams;

  constructor(
    private readonly engine: ScenarioEngine,
    private readonly clock: MockClock,
    private readonly baseDecimals: number,
    private readonly quoteDecimals: number,
    private readonly minOut: { calmBps: number; fallbackBps: number; clampMin: number; clampMax: number }
  ) {
    const baseScale = 10n ** BigInt(baseDecimals);
    const quoteScale = 10n ** BigInt(quoteDecimals);
    this.tokens = {
      base: '0x0000000000000000000000000000000000000B45',
      quote: '0x0000000000000000000000000000000000000C5C',
      baseDecimals,
      quoteDecimals,
      baseScale,
      quoteScale
    };
    this.config = {
      oracle: defaultOracleConfig(),
      inventory: defaultInventoryConfig(baseScale),
      fee: defaultFeeConfig(),
      maker: defaultMakerConfig(quoteScale),
      featureFlags: buildFeatureFlags(this.engine.getParams(this.clock.now()))
    };
    this.lastParams = this.engine.getParams(this.clock.now());
  }

  private refreshParams(): ScenarioParams {
    this.lastParams = this.engine.getParams(this.clock.now());
    this.config.featureFlags = buildFeatureFlags(this.lastParams);
    return this.lastParams;
  }

  async getTokens(): Promise<PoolTokens> {
    return this.tokens;
  }

  async getConfig(): Promise<PoolConfig> {
    this.refreshParams();
    return this.config;
  }

  async getState(): Promise<PoolState> {
    const params = this.refreshParams();
    const baseReserves = computeBaseReserves(this.config.inventory.targetBaseXstar, params);
    const quoteReserves = computeQuoteReserves(baseReserves, toWad(params.mid), this.tokens.quoteScale);
    return {
      baseReserves,
      quoteReserves,
      lastMidWad: toWad(params.mid),
      snapshotAgeSec: 1,
      snapshotTimestamp: this.clock.nowSeconds(),
      sigmaBps: params.conf_bps
    };
  }

  async getPreviewLadder(): Promise<never> {
    throw new Error('preview ladder not implemented in mock mode');
  }

  async previewFees(sizes: readonly bigint[]): Promise<{ ask: number[]; bid: number[] }> {
    const params = this.refreshParams();
    const base = computeBaseReserves(this.config.inventory.targetBaseXstar, params);
    const fees = sizes.map((size) => {
      const ratioBps = Number(size * BPS / (base === 0n ? 1n : base));
      return computeFeeBps(params, ratioBps);
    });
    return { ask: fees, bid: fees };
  }

  async quoteExactIn(amountIn: bigint, isBaseIn: boolean, _oracleMode: number, _oracleData: string): Promise<QuotePreviewResult> {
    const params = this.refreshParams();
    const midWad = toWad(params.mid);
    const tradeMid = isBaseIn ? applyBps(midWad, -params.spread_bps / 2) : applyBps(midWad, params.spread_bps / 2);
    const grossOut = isBaseIn ? (amountIn * tradeMid) / WAD : (amountIn * WAD) / tradeMid;
    const baseReserves = computeBaseReserves(this.config.inventory.targetBaseXstar, params);
    const sizeRatioBps = Number(amountIn * BPS / (baseReserves === 0n ? 1n : baseReserves));
    const feeBps = computeFeeBps(params, sizeRatioBps);
    const fee = (grossOut * BigInt(feeBps)) / BPS;
    const netOut = grossOut > fee ? grossOut - fee : 0n;

    const partialFill = params.inventory_dev_pct && params.inventory_dev_pct >= 7 && isBaseIn
      ? amountIn / 2n
      : amountIn;

    return {
      amountOut: netOut,
      midUsed: tradeMid,
      feeBpsUsed: feeBps,
      partialFillAmountIn: partialFill,
      usedFallback: Boolean(params.pyth_stale || params.fallback),
      reason: params.aomq ? 'AOMQ triggered' : 'mock'
    };
  }

  computeRegimeFlags(params: {
    poolState: PoolState;
    config: PoolConfig;
    usedFallback: boolean;
    clampFlags: RegimeFlag[];
  }): RegimeFlags {
    const flags = new Set<RegimeFlag>();
    params.clampFlags.forEach((flag) => flags.add(flag));
    if (params.usedFallback || this.lastParams.pyth_stale || this.lastParams.fallback) {
      flags.add('Fallback');
    }
    if (this.lastParams.aomq) {
      flags.add('AOMQ');
    }
    if (this.lastParams.inventory_dev_pct && this.lastParams.inventory_dev_pct >= 7) {
      flags.add('NearFloor');
    }
    if (
      params.config.featureFlags.enableSizeFee &&
      (this.lastParams.delta_bps > 30 || this.lastParams.spread_bps > 20)
    ) {
      flags.add('SizeFee');
    }
    if (params.config.featureFlags.enableInvTilt && (this.lastParams.inventory_dev_pct ?? 0) > 0) {
      flags.add('InvTilt');
    }

    let bitmask = 0;
    for (const flag of flags) {
      bitmask |= REGIME_BIT_VALUES[flag];
    }

    return {
      bitmask,
      asArray: Array.from(flags)
    };
  }

  computeGuaranteedMinOutBps(flags: RegimeFlags): number {
    const { calmBps, fallbackBps, clampMin, clampMax } = this.minOut;
    const needsFallback = flags.asArray.includes('Fallback') || flags.asArray.includes('AOMQ');
    const unclamped = needsFallback ? fallbackBps : calmBps;
    return Math.min(Math.max(unclamped, clampMin), clampMax);
  }
}
