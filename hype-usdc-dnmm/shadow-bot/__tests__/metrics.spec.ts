import { describe, expect, test } from 'vitest';
import { createMetricsManager } from '../metrics.js';
import { ShadowBotLabels, ShadowBotConfig, HistogramBuckets } from '../types.js';

const LABELS: ShadowBotLabels = {
  pair: 'HYPE/USDC',
  chain: 'HypeEVM',
  baseSymbol: 'HYPE',
  quoteSymbol: 'USDC'
};

const BUCKETS: HistogramBuckets = {
  deltaBps: [5, 10],
  confBps: [5, 10],
  bboSpreadBps: [5, 10],
  quoteLatencyMs: [10, 20],
  feeBps: [10, 20],
  totalBps: [10, 20]
};

function buildMockConfig(): ShadowBotConfig {
  return {
    mode: 'mock',
    labels: LABELS,
    sizeGrid: [10n ** 18n],
    intervalMs: 1_000,
    snapshotMaxAgeSec: 30,
    histogramBuckets: BUCKETS,
    promPort: 9464,
    logLevel: 'debug',
    csvDirectory: '/tmp',
    jsonSummaryPath: '/tmp/summary.json',
    sizesSource: 'test',
    guaranteedMinOut: {
      calmBps: 10,
      fallbackBps: 20,
      clampMin: 5,
      clampMax: 25
    },
    sampling: {
      intervalLabel: '1s',
      timeoutMs: 1000,
      retryBackoffMs: 100,
      retryAttempts: 1
    },
    baseDecimals: 18,
    quoteDecimals: 6,
    scenarioName: 'CALM',
    scenarioFile: undefined
  };
}

describe('MetricsManager', () => {
  test('adds mode label to gauges', async () => {
    const metrics = createMetricsManager(buildMockConfig());
    metrics.recordPoolState({
      baseReserves: 1_000n,
      quoteReserves: 2_000n,
      lastMidWad: 1_000_000_000_000_000_000n,
      snapshotAgeSec: 1,
      snapshotTimestamp: Date.now()
    });

    const snapshotMetrics = await metrics.getRegister().getMetricsAsJSON();
    const baseReservesMetric = snapshotMetrics.find((metric) => metric.name === 'dnmm_pool_base_reserves');
    expect(baseReservesMetric).toBeDefined();
    const labels = baseReservesMetric?.values?.[0]?.labels ?? {};
    expect(labels.mode).toBe('mock');
  });
});
