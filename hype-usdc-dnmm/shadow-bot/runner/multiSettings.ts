import {
  BENCHMARK_IDS,
  BenchmarkAdapter,
  BenchmarkId,
  BenchmarkQuoteSample,
  BenchmarkTradeResult,
  ChainRuntimeConfig,
  MultiRunRuntimeConfig,
  QuoteCsvRecord,
  RunSettingDefinition,
  ScoreboardRow,
  TradeCsvRecord,
  TradeIntent
} from '../types.js';
import { createFlowEngine, defaultTickMs, FlowEngine, FlowEngineOptions } from '../flows/patterns.js';
import { CpmmBenchmarkAdapter } from '../benchmarks/cpmm.js';
import { StableSwapBenchmarkAdapter } from '../benchmarks/stableswap.js';
import { DnmmBenchmarkAdapter } from '../benchmarks/dnmm.js';
import { ScoreboardAggregator } from './scoreboard.js';
import { createMetricsManager, MetricsManager } from '../metrics.js';
import { createCsvWriter, CsvWriter } from '../csvWriter.js';
import { createLiveChainClient } from '../providers.js';
import { LivePoolClient } from '../poolClient.js';
import { LiveOracleReader } from '../oracleReader.js';

const DEFAULT_TICK_MS = defaultTickMs();

interface RunnerContext {
  readonly config: MultiRunRuntimeConfig;
  readonly metrics: MetricsManager;
  readonly csv: CsvWriter;
  readonly scoreboard: ScoreboardAggregator;
}

export interface RunnerResult {
  readonly scoreboard: ScoreboardRow[];
}

interface RunnerDependencies {
  buildFlowEngine: (config: RunSettingDefinition['flow'], options: FlowEngineOptions) => FlowEngine;
  prepareAdapters: (
    chain: ChainRuntimeConfig | undefined,
    setting: RunSettingDefinition,
    benchmarks: readonly BenchmarkId[]
  ) => Promise<PreparedAdapters>;
}

const defaultDependencies: RunnerDependencies = {
  buildFlowEngine: createFlowEngine,
  prepareAdapters: defaultPrepareAdapters
};

export async function runMultiSettings(
  config: MultiRunRuntimeConfig,
  deps: Partial<RunnerDependencies> = {}
): Promise<RunnerResult> {
  const resolvedDeps: RunnerDependencies = { ...defaultDependencies, ...deps };
  const metrics = createMetricsManager(config);
  const csv = createCsvWriter(config);
  const scoreboard = new ScoreboardAggregator(config.runs, config.benchmarks.length ? config.benchmarks : BENCHMARK_IDS);

  await metrics.start();
  await csv.init();

  const context: RunnerContext = { config, metrics, csv, scoreboard };
  const tasks = config.runs.map((run) => () => runSetting(context, run, resolvedDeps));
  await executeWithConcurrency(tasks, config.maxParallel);

  const rows = scoreboard.buildRows();
  await csv.writeScoreboard(rows);
  await metrics.stop();
  await csv.close();

  return { scoreboard: rows };
}

async function runSetting(
  ctx: RunnerContext,
  setting: RunSettingDefinition,
  deps: RunnerDependencies
): Promise<void> {
  const { config } = ctx;
  const durationSec = config.durationOverrideSec
    ? Math.min(setting.flow.seconds, config.durationOverrideSec)
    : setting.flow.seconds;
  const durationMs = durationSec * 1_000;
  const tickMs = DEFAULT_TICK_MS;
  const startMs = Date.now();
  const engine = buildFlowEngine(setting, startMs, durationMs, deps.buildFlowEngine);

  const benchmarkIds = config.benchmarks.length > 0 ? config.benchmarks : BENCHMARK_IDS;
  const { adapters, cleanup } = await deps.prepareAdapters(config.chain, setting, benchmarkIds);

  try {
    let timestampMs = startMs;
    while (!engine.isComplete(timestampMs)) {
      const intents = engine.next(timestampMs);
      await processTick(ctx, setting, adapters, intents, timestampMs);
      timestampMs += tickMs;
    }
  } finally {
    await Promise.all(adapters.map((adapter) => adapter.close()));
    await cleanup();
  }
}

async function processTick(
  ctx: RunnerContext,
  setting: RunSettingDefinition,
  adapters: readonly BenchmarkAdapter[],
  intents: readonly TradeIntent[],
  timestampMs: number
): Promise<void> {
  const { metrics, csv, scoreboard } = ctx;

  await Promise.all(
    adapters.map(async (adapter) => {
      const quotes = await sampleQuotes(adapter, setting, timestampMs);
      const metricsContext = metrics.context(setting.id, adapter.id);
      const twoSided = await recordQuotes(metricsContext, csv, setting, adapter.id, quotes, timestampMs);
      scoreboard.recordTwoSided(setting.id, adapter.id, twoSided);

      const intentsForAdapter = intents.map((intent) => ({ ...intent }));
      for (const intent of intentsForAdapter) {
        const result = await adapter.simulateTrade(intent);
        await handleTradeResult(metricsContext, csv, scoreboard, setting, adapter.id, result);
      }
    })
  );
}

async function sampleQuotes(
  adapter: BenchmarkAdapter,
  setting: RunSettingDefinition,
  timestampMs: number
): Promise<{ baseIn: BenchmarkQuoteSample; quoteIn: BenchmarkQuoteSample }> {
  const baseSize = BigInt(Math.round(setting.flow.size.min * 1e6));
  const baseSizeWad = baseSize * 10n ** 12n;
  const [baseIn, quoteIn] = await Promise.all([
    adapter.sampleQuote('base_in', baseSizeWad),
    adapter.sampleQuote('quote_in', baseSizeWad)
  ]);
  return { baseIn: { ...baseIn, timestampMs }, quoteIn: { ...quoteIn, timestampMs } };
}

async function recordQuotes(
  metricsContext: ReturnType<MetricsManager['context']>,
  csv: CsvWriter,
  setting: RunSettingDefinition,
  benchmark: BenchmarkId,
  samples: { baseIn: BenchmarkQuoteSample; quoteIn: BenchmarkQuoteSample },
  timestampMs: number
): Promise<boolean> {
  const { baseIn, quoteIn } = samples;
  metricsContext.recordQuote(baseIn);
  metricsContext.recordQuote(quoteIn);

  const quoteRecords: QuoteCsvRecord[] = [
    quoteSampleToCsv(setting.id, benchmark, baseIn),
    quoteSampleToCsv(setting.id, benchmark, quoteIn)
  ];
  await csv.appendQuotes(quoteRecords);
  const baseOk = baseIn.mid > 0n;
  const quoteOk = quoteIn.mid > 0n;
  metricsContext.recordTwoSided(timestampMs, baseOk && quoteOk);
  return baseOk && quoteOk;
}

async function handleTradeResult(
  metricsContext: ReturnType<MetricsManager['context']>,
  csv: CsvWriter,
  scoreboard: ScoreboardAggregator,
  setting: RunSettingDefinition,
  benchmark: BenchmarkId,
  result: BenchmarkTradeResult
): Promise<void> {
  if (result.success) {
    metricsContext.recordTrade(result);
  } else {
    metricsContext.recordReject();
  }
  scoreboard.recordTrade(setting.id, benchmark, result);
  const record = tradeResultToCsv(setting.id, benchmark, result);
  await csv.appendTrades([record]);
}

function buildFlowEngine(
  setting: RunSettingDefinition,
  startMs: number,
  durationMs: number,
  factory: RunnerDependencies['buildFlowEngine']
): FlowEngine {
  const options: FlowEngineOptions = {
    settingId: setting.id,
    durationMs,
    routerTtlMs: setting.router.ttlSec * 1_000,
    routerSlippageBps: setting.router.slippageBps,
    startTimestampMs: startMs
  };
  return factory(setting.flow, options);
}

interface PreparedAdapters {
  readonly adapters: BenchmarkAdapter[];
  readonly cleanup: () => Promise<void>;
}

async function defaultPrepareAdapters(
  chain: ChainRuntimeConfig | undefined,
  setting: RunSettingDefinition,
  benchmarks: readonly BenchmarkId[]
): Promise<PreparedAdapters> {
  if (!chain) {
    throw new Error('Chain configuration is required for live/fork modes');
  }
  const chainClient = createLiveChainClient(chain);
  const poolClient = new LivePoolClient(chain, chainClient);
  const oracleReader = new LiveOracleReader(chain, chainClient);
  const state = await poolClient.getState();

  const adapters: BenchmarkAdapter[] = [];
  for (const benchmark of benchmarks) {
    if (benchmark === 'dnmm') {
      const adapter = new DnmmBenchmarkAdapter({ chain, poolClient, oracleReader });
      await adapter.init();
      adapters.push(adapter);
    } else if (benchmark === 'cpmm') {
      const adapter = new CpmmBenchmarkAdapter({
        baseDecimals: chain.baseDecimals,
        quoteDecimals: chain.quoteDecimals,
        baseReserves: state.baseReserves,
        quoteReserves: state.quoteReserves
      });
      await adapter.init();
      adapters.push(adapter);
    } else if (benchmark === 'stableswap') {
      const adapter = new StableSwapBenchmarkAdapter({
        baseDecimals: chain.baseDecimals,
        quoteDecimals: chain.quoteDecimals,
        baseReserves: state.baseReserves,
        quoteReserves: state.quoteReserves
      });
      await adapter.init();
      adapters.push(adapter);
    }
  }
  return {
    adapters,
    cleanup: () => chainClient.close()
  };
}

function tradeResultToCsv(settingId: string, benchmark: BenchmarkId, result: BenchmarkTradeResult): TradeCsvRecord {
  const tsIso = new Date(result.intent.timestampMs).toISOString();
  return {
    tsIso,
    settingId,
    benchmark,
    side: result.intent.side,
    amountIn: result.amountIn.toString(),
    amountOut: result.amountOut.toString(),
    midUsed: result.midUsed.toString(),
    feeBpsUsed: result.feeBpsUsed,
    floorBps: result.floorBps ?? 0,
    tiltBps: result.tiltBps ?? 0,
    aomqClamped: result.aomqClamped,
    minOut: result.minOut?.toString(),
    slippageBpsVsMid: result.slippageBpsVsMid,
    pnlQuote: result.pnlQuote,
    inventoryBase: result.inventoryBase.toString(),
    inventoryQuote: result.inventoryQuote.toString()
  };
}

function quoteSampleToCsv(settingId: string, benchmark: BenchmarkId, sample: BenchmarkQuoteSample): QuoteCsvRecord {
  return {
    tsIso: new Date(sample.timestampMs).toISOString(),
    settingId,
    benchmark,
    side: sample.side,
    sizeBaseWad: sample.sizeBaseWad.toString(),
    feeBps: sample.feeBps,
    mid: sample.mid.toString(),
    spreadBps: sample.spreadBps,
    confBps: sample.confBps,
    aomqActive: sample.aomqActive
  };
}

async function executeWithConcurrency<T>(tasks: readonly (() => Promise<T>)[], limit: number): Promise<T[]> {
  const results: T[] = new Array(tasks.length);
  let cursor = 0;
  const workers = new Array(Math.max(1, Math.min(limit, tasks.length))).fill(null).map(async () => {
    while (true) {
      const current = cursor;
      cursor += 1;
      if (current >= tasks.length) {
        break;
      }
      const value = await tasks[current]();
      results[current] = value;
    }
  });
  await Promise.all(workers);
  return results;
}
