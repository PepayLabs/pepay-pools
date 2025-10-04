import { Contract } from 'ethers';
import { IDNM_POOL_ABI } from './abis.js';
import {
  ChainRuntimeConfig,
  ChainClient,
  FeatureFlagsState,
  FeeConfigState,
  InventoryConfigState,
  MakerConfigState,
  OracleConfigState,
  PoolClientAdapter,
  PoolConfig,
  PoolState,
  PoolTokens,
  RegimeFlag,
  RegimeFlags,
  REGIME_BIT_VALUES,
  PreviewLadderSnapshot,
  QuotePreviewResult
} from './types.js';

const BPS = 10_000n;
export class LivePoolClient implements PoolClientAdapter {
  private readonly contract: Contract;
  private tokensCache?: PoolTokens;
  private configCache?: PoolConfig;

  constructor(
    private readonly runtime: ChainRuntimeConfig,
    private readonly chainClient: ChainClient,
    contractOverride?: Contract
  ) {
    const provider = chainClient.getRpcProvider();
    if (!provider) {
      throw new Error('LivePoolClient requires an RPC provider');
    }
    this.contract = contractOverride ?? new Contract(runtime.poolAddress, IDNM_POOL_ABI, provider);
  }

  async getTokens(force = false): Promise<PoolTokens> {
    if (!force && this.tokensCache) return this.tokensCache;
    const result = await this.chainClient.request('tokens', () => this.contract.tokens());
    const tokens: PoolTokens = {
      base: result.baseToken as string,
      quote: result.quoteToken as string,
      baseDecimals: Number(result.baseDecimals),
      quoteDecimals: Number(result.quoteDecimals),
      baseScale: BigInt(result.baseScale),
      quoteScale: BigInt(result.quoteScale)
    };
    this.tokensCache = tokens;
    return tokens;
  }

  async getConfig(force = false): Promise<PoolConfig> {
    if (!force && this.configCache) return this.configCache;

    const [oracleRaw, inventoryRaw, feeRaw, makerRaw, flagsRaw] = await Promise.all([
      this.chainClient.request('oracleConfig', () => this.contract.oracleConfig()),
      this.chainClient.request('inventoryConfig', () => this.contract.inventoryConfig()),
      this.chainClient.request('feeConfig', () => this.contract.feeConfig()),
      this.chainClient.request('makerConfig', () => this.contract.makerConfig()),
      this.chainClient.request('featureFlags', () => this.contract.featureFlags())
    ]);

    const oracleConfig: OracleConfigState = {
      maxAgeSec: Number(oracleRaw.maxAgeSec ?? oracleRaw[0]),
      stallWindowSec: Number(oracleRaw.stallWindowSec ?? oracleRaw[1]),
      confCapBpsSpot: Number(oracleRaw.confCapBpsSpot ?? oracleRaw[2]),
      confCapBpsStrict: Number(oracleRaw.confCapBpsStrict ?? oracleRaw[3]),
      divergenceBps: Number(oracleRaw.divergenceBps ?? oracleRaw[4]),
      allowEmaFallback: Boolean(oracleRaw.allowEmaFallback ?? oracleRaw[5]),
      confWeightSpreadBps: Number(oracleRaw.confWeightSpreadBps ?? oracleRaw[6]),
      confWeightSigmaBps: Number(oracleRaw.confWeightSigmaBps ?? oracleRaw[7]),
      confWeightPythBps: Number(oracleRaw.confWeightPythBps ?? oracleRaw[8]),
      sigmaEwmaLambdaBps: Number(oracleRaw.sigmaEwmaLambdaBps ?? oracleRaw[9]),
      divergenceAcceptBps: Number(oracleRaw.divergenceAcceptBps ?? oracleRaw[10]),
      divergenceSoftBps: Number(oracleRaw.divergenceSoftBps ?? oracleRaw[11]),
      divergenceHardBps: Number(oracleRaw.divergenceHardBps ?? oracleRaw[12]),
      haircutMinBps: Number(oracleRaw.haircutMinBps ?? oracleRaw[13]),
      haircutSlopeBps: Number(oracleRaw.haircutSlopeBps ?? oracleRaw[14])
    };

    const inventoryConfig: InventoryConfigState = {
      targetBaseXstar: BigInt(inventoryRaw.targetBaseXstar ?? inventoryRaw[0]),
      floorBps: Number(inventoryRaw.floorBps ?? inventoryRaw[1]),
      recenterThresholdPct: Number(inventoryRaw.recenterThresholdPct ?? inventoryRaw[2]),
      invTiltBpsPer1pct: Number(inventoryRaw.invTiltBpsPer1pct ?? inventoryRaw[3]),
      invTiltMaxBps: Number(inventoryRaw.invTiltMaxBps ?? inventoryRaw[4]),
      tiltConfWeightBps: Number(inventoryRaw.tiltConfWeightBps ?? inventoryRaw[5]),
      tiltSpreadWeightBps: Number(inventoryRaw.tiltSpreadWeightBps ?? inventoryRaw[6])
    };

    const feeConfig: FeeConfigState = {
      baseBps: Number(feeRaw.baseBps ?? feeRaw[0]),
      alphaNumerator: Number(feeRaw.alphaNumerator ?? feeRaw[1]),
      alphaDenominator: Number(feeRaw.alphaDenominator ?? feeRaw[2]),
      betaInvDevNumerator: Number(feeRaw.betaInvDevNumerator ?? feeRaw[3]),
      betaInvDevDenominator: Number(feeRaw.betaInvDevDenominator ?? feeRaw[4]),
      capBps: Number(feeRaw.capBps ?? feeRaw[5]),
      decayPctPerBlock: Number(feeRaw.decayPctPerBlock ?? feeRaw[6]),
      gammaSizeLinBps: Number(feeRaw.gammaSizeLinBps ?? feeRaw[7]),
      gammaSizeQuadBps: Number(feeRaw.gammaSizeQuadBps ?? feeRaw[8]),
      sizeFeeCapBps: Number(feeRaw.sizeFeeCapBps ?? feeRaw[9])
    };

    const makerConfig: MakerConfigState = {
      s0Notional: BigInt(makerRaw.s0Notional ?? makerRaw[0]),
      ttlMs: Number(makerRaw.ttlMs ?? makerRaw[1]),
      alphaBboBps: Number(makerRaw.alphaBboBps ?? makerRaw[2]),
      betaFloorBps: Number(makerRaw.betaFloorBps ?? makerRaw[3])
    };

    const featureFlags: FeatureFlagsState = {
      blendOn: Boolean(flagsRaw.blendOn ?? flagsRaw[0]),
      parityCiOn: Boolean(flagsRaw.parityCiOn ?? flagsRaw[1]),
      debugEmit: Boolean(flagsRaw.debugEmit ?? flagsRaw[2]),
      enableSoftDivergence: Boolean(flagsRaw.enableSoftDivergence ?? flagsRaw[3]),
      enableSizeFee: Boolean(flagsRaw.enableSizeFee ?? flagsRaw[4]),
      enableBboFloor: Boolean(flagsRaw.enableBboFloor ?? flagsRaw[5]),
      enableInvTilt: Boolean(flagsRaw.enableInvTilt ?? flagsRaw[6]),
      enableAOMQ: Boolean(flagsRaw.enableAOMQ ?? flagsRaw[7]),
      enableRebates: Boolean(flagsRaw.enableRebates ?? flagsRaw[8]),
      enableAutoRecenter: Boolean(flagsRaw.enableAutoRecenter ?? flagsRaw[9])
    };

    const config: PoolConfig = {
      oracle: oracleConfig,
      inventory: inventoryConfig,
      fee: feeConfig,
      maker: makerConfig,
      featureFlags
    };

    this.configCache = config;
    return config;
  }

  async getState(): Promise<PoolState> {
    const [reservesRaw, lastMidRaw, snapshotAgeRaw] = await Promise.all([
      this.chainClient.request('reserves', () => this.contract.reserves()),
      this.chainClient.request('lastMid', () => this.contract.lastMid()),
      this.chainClient.request('previewSnapshotAge', () => this.contract.previewSnapshotAge())
    ]);

    const state: PoolState = {
      baseReserves: BigInt(reservesRaw.baseReserves ?? reservesRaw[0]),
      quoteReserves: BigInt(reservesRaw.quoteReserves ?? reservesRaw[1]),
      lastMidWad: BigInt(lastMidRaw),
      snapshotAgeSec: Number(snapshotAgeRaw.ageSec ?? snapshotAgeRaw[0]),
      snapshotTimestamp: Number(snapshotAgeRaw.snapshotTimestamp ?? snapshotAgeRaw[1])
    };

    return state;
  }

  async getPreviewLadder(s0BaseWad: bigint): Promise<PreviewLadderSnapshot> {
    const result = await this.chainClient.request('previewLadder', () =>
      this.contract.getFunction('previewLadder').staticCall(s0BaseWad)
    );

    const rows: PreviewLadderSnapshot['rows'] = [];
    const sizes: bigint[] = Array.from(result.sizesBaseWad ?? result[0] ?? []);
    const askFees: bigint[] = Array.from(result.askFeeBps ?? result[1] ?? []);
    const bidFees: bigint[] = Array.from(result.bidFeeBps ?? result[2] ?? []);
    const askClamped: boolean[] = Array.from(result.askClamped ?? result[3] ?? []);
    const bidClamped: boolean[] = Array.from(result.bidClamped ?? result[4] ?? []);

    for (let i = 0; i < sizes.length; i += 1) {
      rows.push({
        sizeWad: BigInt(sizes[i]),
        askFeeBps: Number(askFees[i] ?? 0n),
        bidFeeBps: Number(bidFees[i] ?? 0n),
        askClamped: Boolean(askClamped[i]),
        bidClamped: Boolean(bidClamped[i])
      });
    }

    return {
      rows,
      snapshotTimestamp: Number(result.snapshotTimestamp ?? result[5] ?? 0),
      snapshotMidWad: BigInt(result.snapshotMid ?? result[6] ?? 0n)
    };
  }

  async previewFees(sizes: readonly bigint[]): Promise<{ ask: number[]; bid: number[] }> {
    const result = await this.chainClient.request('previewFees', () =>
      this.contract.getFunction('previewFees').staticCall(sizes)
    );
    const askFees: number[] = Array.from(result.askFeeBps ?? result[0] ?? []).map((value) => Number(value));
    const bidFees: number[] = Array.from(result.bidFeeBps ?? result[1] ?? []).map((value) => Number(value));
    return { ask: askFees, bid: bidFees };
  }

  async quoteExactIn(amountIn: bigint, isBaseIn: boolean, oracleMode: number, oracleData: string): Promise<QuotePreviewResult> {
    const func = this.contract.getFunction('quoteSwapExactIn');
    const result = await this.chainClient.request('quoteSwapExactIn', () =>
      func.staticCall(amountIn, isBaseIn, oracleMode, oracleData)
    );

    return {
      amountOut: BigInt(result.amountOut ?? result[0]),
      midUsed: BigInt(result.midUsed ?? result[1]),
      feeBpsUsed: Number(result.feeBpsUsed ?? result[2]),
      partialFillAmountIn: BigInt(result.partialFillAmountIn ?? result[3]),
      usedFallback: Boolean(result.usedFallback ?? result[4]),
      reason: String(result.reason ?? result[5])
    };
  }

  computeRegimeFlags(params: {
    poolState: PoolState;
    config: PoolConfig;
    usedFallback: boolean;
    clampFlags: RegimeFlag[];
  }): RegimeFlags {
    const { poolState, config, usedFallback, clampFlags } = params;
    let bitmask = 0;
    const flags = new Set<RegimeFlag>();

    clampFlags.forEach((flag) => flags.add(flag));

    if (usedFallback) {
      flags.add('Fallback');
    }
    if (config.featureFlags.enableSizeFee) {
      flags.add('SizeFee');
    }
    if (config.featureFlags.enableInvTilt) {
      flags.add('InvTilt');
    }
    if (isNearFloor(poolState, config.inventory)) {
      flags.add('NearFloor');
    }

    for (const flag of flags) {
      bitmask |= REGIME_BIT_VALUES[flag];
    }

    return {
      bitmask,
      asArray: Array.from(flags)
    };
  }

  computeGuaranteedMinOutBps(flags: RegimeFlags): number {
    const needsFallback = flags.asArray.includes('Fallback') || flags.asArray.includes('AOMQ');
    const calmBps = 15;
    const fallbackBps = 120;
    const unclamped = needsFallback ? fallbackBps : calmBps;
    return unclamped;
  }
}

function isNearFloor(state: PoolState, inventory: InventoryConfigState): boolean {
  if (inventory.floorBps === 0) return false;
  const floorAmount = (inventory.targetBaseXstar * BigInt(inventory.floorBps)) / BPS;
  const tolerance = inventory.targetBaseXstar / 100n; // 1% tolerance
  return state.baseReserves <= floorAmount + tolerance;
}
