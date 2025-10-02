import fs from 'fs';
import fsPromises from 'fs/promises';
import os from 'os';
import path from 'path';
import { afterEach, describe, expect, it } from 'vitest';
import { buildCsvRows, createCsvWriter } from '../csvWriter.js';
import { ProbeQuote, ShadowBotConfig } from '../types.js';

let tempDir = '';

afterEach(async () => {
  if (tempDir) {
    await fsPromises.rm(tempDir, { recursive: true, force: true });
    tempDir = '';
  }
});

function tempConfig(): ShadowBotConfig {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'shadowbot-'));
  return {
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
      deltaBps: [10],
      confBps: [10],
      bboSpreadBps: [10],
      quoteLatencyMs: [10],
      feeBps: [10],
      totalBps: [10]
    },
    promPort: 9_464,
    logLevel: 'info',
    csvDirectory: path.join(tempDir, 'metrics'),
    jsonSummaryPath: path.join(tempDir, 'summary.json'),
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
}

describe('CsvWriter', () => {
  it('writes header once and appends rows', async () => {
    const cfg = tempConfig();
    const writer = createCsvWriter(cfg);

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
      clampFlags: [],
      riskBits: [],
      success: true,
      status: 'OK',
      usedFallback: false
    };

    const rows = buildCsvRows([probe], Date.now(), { spreadBps: 50 });
    await writer.appendRows(rows);
    await writer.appendRows(rows);

    const dateKey = new Date(rows[0].timestampMs).toISOString().slice(0, 10).replace(/-/g, '');
    const filePath = path.join(cfg.csvDirectory, `dnmm_shadow_${dateKey}.csv`);
    const content = await fsPromises.readFile(filePath, 'utf8');
    const headerCount = content.split('\n').filter((line) => line.startsWith('ts')).length;
    expect(headerCount).toBe(1);
  });
});
