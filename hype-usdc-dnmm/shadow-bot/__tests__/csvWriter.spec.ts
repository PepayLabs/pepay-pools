import { describe, expect, test } from 'vitest';
import os from 'os';
import path from 'path';
import { mkdtemp, readFile, rm } from 'fs/promises';
import { createCsvWriter, buildCsvRows } from '../csvWriter.js';
import { ProbeQuote, ShadowBotConfig } from '../types.js';

const CONFIG: ShadowBotConfig = {
  mode: 'mock',
  labels: {
    pair: 'HYPE/USDC',
    chain: 'HypeEVM',
    baseSymbol: 'HYPE',
    quoteSymbol: 'USDC'
  },
  sizeGrid: [10n ** 18n],
  intervalMs: 1_000,
  snapshotMaxAgeSec: 30,
  histogramBuckets: {
    deltaBps: [5, 10],
    confBps: [5, 10],
    bboSpreadBps: [5, 10],
    quoteLatencyMs: [10, 20],
    feeBps: [10, 20],
    totalBps: [10, 20]
  },
  promPort: 9464,
  logLevel: 'debug',
  csvDirectory: '',
  jsonSummaryPath: '',
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

const SAMPLE_PROBE: ProbeQuote = {
  side: 'base_in',
  mode: 'exact_in',
  sizeWad: 10n ** 18n,
  amountIn: 10n ** 18n,
  amountOut: 999_000_000_000_000_000n,
  feeBps: 10,
  totalBps: 12,
  slippageBps: 2,
  minOutBps: 10,
  latencyMs: 12,
  clampFlags: [],
  riskBits: [],
  success: true,
  status: 'OK',
  usedFallback: false
};

describe('CsvWriter', () => {
  test('writes header once and appends rows', async () => {
    const tempDir = await mkdtemp(path.join(os.tmpdir(), 'csv-writer-'));
    const config = { ...CONFIG, csvDirectory: tempDir, jsonSummaryPath: path.join(tempDir, 'summary.json') };
    const errors: string[] = [];
    const writer = createCsvWriter(config, {
      error: (_message, meta) => {
        if (meta?.detail) errors.push(String(meta.detail));
      }
    });

    const timestamp = Date.UTC(2025, 0, 1);
    await writer.appendRows(buildCsvRows([SAMPLE_PROBE], timestamp, {}));
    await writer.appendRows(buildCsvRows([SAMPLE_PROBE], timestamp, {}));

    const dateKey = '20250101';
    const filePath = path.join(tempDir, `dnmm_shadow_${dateKey}.csv`);
    const contents = await readFile(filePath, 'utf8');
    const headerCount = contents.split('\n').filter((line) => line.startsWith('ts,size_wad')).length;
    expect(headerCount).toBe(1);
    expect(errors).toHaveLength(0);

    await rm(tempDir, { recursive: true, force: true });
  });
});
