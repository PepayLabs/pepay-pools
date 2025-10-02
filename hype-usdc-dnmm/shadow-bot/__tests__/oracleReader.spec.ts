import { AbiCoder } from 'ethers';
import { describe, expect, it, vi } from 'vitest';
import { OracleReader } from '../oracleReader.js';
import { ShadowBotConfig } from '../types.js';

const coder = AbiCoder.defaultAbiCoder();

const baseConfig: ShadowBotConfig = {
  rpcUrl: 'http://localhost:8545',
  poolAddress: '0x0000000000000000000000000000000000000001',
  pythAddress: '0x0000000000000000000000000000000000000010',
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
  pythPriceId: '0x01',
  addressBookSource: undefined,
  gasPriceGwei: undefined,
  nativeUsd: undefined,
  chainId: 1,
  wsUrl: undefined
};

describe('OracleReader', () => {
  it('decodes HyperCore and Pyth samples', async () => {
    const providerStub = {
      callContract: vi.fn((request: { to: string }, label: string) => {
        if (label === 'hc.mid') {
          return Promise.resolve(coder.encode(['uint64'], [5000n]));
        }
        if (label === 'hc.bbo') {
          return Promise.resolve(coder.encode(['uint64', 'uint64'], [4900n, 5100n]));
        }
        throw new Error(`Unexpected label ${label}`);
      }),
      request: vi.fn((_label: string, fn: () => unknown) => Promise.resolve(fn()))
    } as any;

    const pythFunction = {
      staticCall: vi.fn(() => Promise.resolve({
        price: 5_000_000n,
        conf: 10_000_000_000_000n,
        expo: -8,
        publishTime: 1_700_000_000n
      }))
    };

    const pythStub = {
      getFunction: vi.fn(() => pythFunction)
    } as any;

    const reader = new OracleReader(baseConfig, providerStub, pythStub);
    const snapshot = await reader.sample();

    expect(snapshot.hc.status).toBe('ok');
    expect(snapshot.hc.midWad).toBe(5000n * baseConfig.hcPxMultiplier);
    expect(snapshot.hc.spreadBps).toBeGreaterThan(0);

    expect(snapshot.pyth?.status).toBe('ok');
    expect(snapshot.pyth?.confBps).toBeGreaterThan(0);
    expect(snapshot.pyth?.publishTimeSec).toBe(1_700_000_000);
  });
});
