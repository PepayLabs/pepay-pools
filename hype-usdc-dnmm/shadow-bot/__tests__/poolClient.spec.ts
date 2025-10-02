import { Contract } from 'ethers';
import { describe, expect, it } from 'vitest';
import { PoolClient } from '../poolClient.js';
import { REGIME_BIT_VALUES, ShadowBotConfig } from '../types.js';

function tupleWithNames<T extends Record<string, unknown>>(values: T): T & unknown[] {
  const result: any = [];
  let index = 0;
  for (const [key, value] of Object.entries(values)) {
    result[index] = value;
    (result as any)[key] = value;
    index += 1;
  }
  return result as T & unknown[];
}

const baseConfig: ShadowBotConfig = {
  rpcUrl: 'http://localhost:8545',
  poolAddress: '0x0000000000000000000000000000000000000001',
  pythAddress: undefined,
  hcPxPrecompile: '0x0000000000000000000000000000000000000807',
  hcBboPrecompile: '0x000000000000000000000000000000000000080e',
  hcPxKey: 1,
  hcBboKey: 1,
  hcMarketType: 'spot',
  hcSizeDecimals: 2,
  hcPxMultiplier: 10n ** 12n,
  baseTokenAddress: '0x0000000000000000000000000000000000000002',
  quoteTokenAddress: '0x0000000000000000000000000000000000000003',
  baseDecimals: 18,
  quoteDecimals: 6,
  labels: { pair: 'HYPE/USDC', chain: 'HypeEVM', baseSymbol: 'HYPE', quoteSymbol: 'USDC' },
  sizeGrid: [1n, 2n],
  intervalMs: 1_000,
  snapshotMaxAgeSec: 30,
  histogramBuckets: {
    deltaBps: [10],
    confBps: [10],
    bboSpreadBps: [10],
    quoteLatencyMs: [10],
    feeBps: [10],
    totalBps: [10]
  },
  promPort: 9_464,
  logLevel: 'info',
  csvDirectory: '/tmp',
  jsonSummaryPath: '/tmp/summary.json',
  sizesSource: 'default',
  guaranteedMinOut: { calmBps: 10, fallbackBps: 20, clampMin: 5, clampMax: 25 },
  sampling: { intervalLabel: '1000ms', timeoutMs: 1_000, retryBackoffMs: 100, retryAttempts: 1 },
  pythPriceId: undefined,
  addressBookSource: undefined,
  gasPriceGwei: undefined,
  nativeUsd: undefined,
  chainId: 1,
  wsUrl: undefined
};

describe('PoolClient', () => {
  it('loads tokens and config with proper typing', async () => {
    const contractStub = {
      tokens: () => Promise.resolve({
        baseToken: baseConfig.baseTokenAddress,
        quoteToken: baseConfig.quoteTokenAddress,
        baseDecimals: 18,
        quoteDecimals: 6,
        baseScale: 10n ** 18n,
        quoteScale: 10n ** 6n
      }),
      oracleConfig: () => Promise.resolve(tupleWithNames({
        maxAgeSec: 30n,
        stallWindowSec: 120n,
        confCapBpsSpot: 50n,
        confCapBpsStrict: 60n,
        divergenceBps: 25n,
        allowEmaFallback: true,
        confWeightSpreadBps: 100n,
        confWeightSigmaBps: 200n,
        confWeightPythBps: 300n,
        sigmaEwmaLambdaBps: 400n,
        divergenceAcceptBps: 15n,
        divergenceSoftBps: 20n,
        divergenceHardBps: 30n,
        haircutMinBps: 1n,
        haircutSlopeBps: 2n
      })),
      inventoryConfig: () => Promise.resolve(tupleWithNames({
        targetBaseXstar: 100n,
        floorBps: 1n,
        recenterThresholdPct: 5n,
        invTiltBpsPer1pct: 2n,
        invTiltMaxBps: 8n,
        tiltConfWeightBps: 3n,
        tiltSpreadWeightBps: 4n
      })),
      feeConfig: () => Promise.resolve(tupleWithNames({
        baseBps: 10n,
        alphaNumerator: 1n,
        alphaDenominator: 100n,
        betaInvDevNumerator: 1n,
        betaInvDevDenominator: 50n,
        capBps: 30n,
        decayPctPerBlock: 2n,
        gammaSizeLinBps: 5n,
        gammaSizeQuadBps: 6n,
        sizeFeeCapBps: 70n
      })),
      makerConfig: () => Promise.resolve(tupleWithNames({
        s0Notional: 1_000n,
        ttlMs: 250n,
        alphaBboBps: 4n,
        betaFloorBps: 3n
      })),
      featureFlags: () => Promise.resolve(tupleWithNames({
        blendOn: true,
        parityCiOn: false,
        debugEmit: false,
        enableSoftDivergence: true,
        enableSizeFee: true,
        enableBboFloor: false,
        enableInvTilt: true,
        enableAOMQ: false,
        enableRebates: true,
        enableAutoRecenter: true
      }))
    } as unknown as Contract;

    const providerStub = {
      rpc: {} as any,
      request: (_label: string, fn: () => unknown) => Promise.resolve(fn())
    } as any;

    const client = new PoolClient(baseConfig, providerStub, contractStub);

    const tokens = await client.getTokens(true);
    expect(tokens.base).toBe(baseConfig.baseTokenAddress);
    expect(tokens.baseScale).toBe(10n ** 18n);

    const cfg = await client.getConfig(true);
    expect(cfg.fee.baseBps).toBe(10);
    expect(cfg.featureFlags.enableInvTilt).toBe(true);
    expect(cfg.inventory.targetBaseXstar).toBe(100n);
  });

  it('computes regime flags and min out policy', () => {
    const providerStub = {
      rpc: {} as any,
      request: (_label: string, fn: () => unknown) => Promise.resolve(fn())
    } as any;

    const client = new PoolClient(baseConfig, providerStub, {} as Contract);

    const regime = client.computeRegimeFlags({
      poolState: {
        baseReserves: 90n,
        quoteReserves: 100n,
        lastMidWad: 10n ** 18n
      },
      config: {
        oracle: cfgOracle(),
        inventory: {
          targetBaseXstar: 100n,
          floorBps: 1,
          recenterThresholdPct: 5,
          invTiltBpsPer1pct: 0,
          invTiltMaxBps: 0,
          tiltConfWeightBps: 0,
          tiltSpreadWeightBps: 0
        },
        fee: cfgFee(),
        maker: cfgMaker(),
        featureFlags: {
          blendOn: true,
          parityCiOn: false,
          debugEmit: false,
          enableSoftDivergence: true,
          enableSizeFee: true,
          enableBboFloor: false,
          enableInvTilt: true,
          enableAOMQ: false,
          enableRebates: true,
          enableAutoRecenter: true
        }
      },
      usedFallback: true,
      clampFlags: ['AOMQ']
    });

    expect(regime.asArray).toContain('AOMQ');
    expect(regime.asArray).toContain('Fallback');
    expect(regime.bitmask & REGIME_BIT_VALUES.AOMQ).toBeGreaterThan(0);

    const minOut = client.computeGuaranteedMinOutBps(regime);
    expect(minOut).toBe(20);
  });
});

function cfgOracle() {
  return {
    maxAgeSec: 30,
    stallWindowSec: 120,
    confCapBpsSpot: 50,
    confCapBpsStrict: 60,
    divergenceBps: 25,
    allowEmaFallback: true,
    confWeightSpreadBps: 100,
    confWeightSigmaBps: 200,
    confWeightPythBps: 300,
    sigmaEwmaLambdaBps: 400,
    divergenceAcceptBps: 10,
    divergenceSoftBps: 20,
    divergenceHardBps: 30,
    haircutMinBps: 1,
    haircutSlopeBps: 2
  };
}

function cfgFee() {
  return {
    baseBps: 10,
    alphaNumerator: 1,
    alphaDenominator: 100,
    betaInvDevNumerator: 1,
    betaInvDevDenominator: 50,
    capBps: 30,
    decayPctPerBlock: 2,
    gammaSizeLinBps: 5,
    gammaSizeQuadBps: 6,
    sizeFeeCapBps: 70
  };
}

function cfgMaker() {
  return {
    s0Notional: 1_000n,
    ttlMs: 250,
    alphaBboBps: 4,
    betaFloorBps: 3
  };
}
