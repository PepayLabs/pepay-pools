import { describe, expect, it } from 'vitest';
import { createMetricsManager } from '../metrics.js';
import { ProbeQuote, ShadowBotConfig } from '../types.js';

const config: ShadowBotConfig = {
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
  sizeGrid: [1n],
  intervalMs: 1_000,
  snapshotMaxAgeSec: 30,
  histogramBuckets: {
    deltaBps: [10, 20],
    confBps: [10],
    bboSpreadBps: [10],
    quoteLatencyMs: [10, 20],
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

describe('MetricsManager', () => {
  it('exports prometheus text without NaN values', async () => {
    const metrics = createMetricsManager(config);

    metrics.recordPoolState({
      baseReserves: 100n,
      quoteReserves: 3_000n,
      lastMidWad: 30n * 10n ** 18n,
      snapshotAgeSec: 5
    });

    const probe: ProbeQuote = {
      side: 'base_in',
      mode: 'exact_in',
      sizeWad: 1n,
      amountIn: 1n,
      amountOut: 30n,
      feeBps: 12,
      totalBps: 15,
      slippageBps: 3,
      minOutBps: 10,
      latencyMs: 12,
      clampFlags: ['AOMQ'],
      riskBits: ['AOMQ'],
      success: true,
      status: 'OK',
      usedFallback: false
    };

    metrics.recordProbe(probe, 0, 'AOMQ');
    metrics.recordQuoteResult('ok');
    metrics.recordTwoSided(Date.now(), true);

    const text = await metrics.getRegister().metrics();
    expect(text).toContain('dnmm_pool_base_reserves');
    expect(text).not.toContain('NaN');
  });
});
