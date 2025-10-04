import {
  BENCHMARK_IDS,
  BenchmarkAdapter,
  BenchmarkId,
  BenchmarkQuoteSample,
  BenchmarkTradeResult,
  BenchmarkTickContext,
  MultiRunRuntimeConfig,
  OracleSnapshot,
  PoolState,
  QuoteCsvRecord,
  RunSettingDefinition,
  ScoreboardRow,
  TradeCsvRecord,
  TradeIntent,
  isChainBackedConfig,
  ChainBackedConfig,
  MockShadowBotConfig,
  ChainRuntimeConfig
} from '../types.js';
import { createFlowEngine, defaultTickMs, FlowEngine, FlowEngineOptions } from '../flows/patterns.js';
import { DnmmBenchmarkAdapter } from '../benchmarks/dnmm.js';
import { CpmmBenchmarkAdapter } from '../benchmarks/cpmm.js';
import { StableSwapBenchmarkAdapter } from '../benchmarks/stableswap.js';
import { ScoreboardAggregator } from './scoreboard.js';
import { MultiMetricsManager } from '../metrics/multi.js';
import { createMultiCsvWriter, MultiCsvWriter } from '../csv/multiWriter.js';
import { createLiveChainClient } from '../providers.js';
import { LivePoolClient } from '../poolClient.js';
import { LiveOracleReader } from '../oracleReader.js';
import { SimPoolClient } from '../sim/simPool.js';
import { SimOracleReader } from '../sim/simOracle.js';

const DEFAULT_TICK_MS = defaultTickMs();

interface RunnerContext {
  readonly runtime: MultiRunRuntimeConfig;
  readonly metrics: MultiMetricsManager;
  readonly csv: MultiCsvWriter;
  readonly scoreboard: ScoreboardAggregator;
}

interface PreparedTickResources {
  readonly adapters: BenchmarkAdapter[];
  readonly fetchOracle: () => Promise<OracleSnapshot>;
  readonly fetchPoolState: () => Promise<PoolState>;
  readonly cleanup: () => Promise<void>;
}

export interface RunnerResult {
  readonly scoreboard: ScoreboardRow[];
}

export async function runMultiSettings(config: MultiRunRuntimeConfig): Promise<RunnerResult> {
  const metrics = new MultiMetricsManager(config);
  const csv = createMultiCsvWriter(config);
  const scoreboard = new ScoreboardAggregator(
    config.runs,
    config.benchmarks.length > 0 ? config.benchmarks : BENCHMARK_IDS,
    {
      baseDecimals: config.baseConfig.baseDecimals,
      quoteDecimals: config.baseConfig.quoteDecimals
    }
  );

  await metrics.start();
  await csv.init();

  const ctx: RunnerContext = { runtime: config, metrics, csv, scoreboard };
  const tasks = config.runs.map((run) => () => runSingleSetting(ctx, run));
  await executeWithConcurrency(tasks, config.maxParallel);

  const rows = scoreboard.buildRows();
  await csv.writeScoreboard(rows);

  await csv.close();
  await metrics.stop();

  return { scoreboard: rows };
}

async function runSingleSetting(ctx: RunnerContext, setting: RunSettingDefinition): Promise<void> {
  const { runtime } = ctx;
  const durationSec = runtime.durationOverrideSec
    ? Math.min(setting.flow.seconds, runtime.durationOverrideSec)
    : setting.flow.seconds;
  const durationMs = durationSec * 1_000;
  const tickMs = DEFAULT_TICK_MS;
  const startMs = Date.now();
  const engine = buildFlowEngine(setting, startMs, durationMs);

  const benchmarks = runtime.benchmarks.length > 0 ? runtime.benchmarks : BENCHMARK_IDS;
  const tickResources = await prepareAdapters(runtime, setting, benchmarks);

  try {
    let timestampMs = startMs;
    while (!engine.isComplete(timestampMs)) {
      const intents = engine.next(timestampMs);
      await processTick(ctx, setting, tickResources, intents, timestampMs);
      timestampMs += tickMs;
    }
  } finally {
    await Promise.all(tickResources.adapters.map((adapter) => adapter.close()))
      .catch(() => undefined);
    await tickResources.cleanup();
  }
}

async function processTick(
  ctx: RunnerContext,
  setting: RunSettingDefinition,
  resources: PreparedTickResources,
  intents: readonly TradeIntent[],
  timestampMs: number
): Promise<void> {
  const { metrics, csv, scoreboard, runtime } = ctx;
  const oracle = await resources.fetchOracle();
  const poolState = await resources.fetchPoolState();

  await Promise.all(
    resources.adapters.map(async (adapter) => {
      await adapter.prepareTick({ timestampMs, oracle, poolState });
      const metricsContext = metrics.context(setting.id, adapter.id);
      metricsContext.recordOracle({
        mid: oracle.hc.midWad ?? 0n,
        spreadBps: oracle.hc.spreadBps,
        confBps: oracle.pyth?.confBps
      });

      const quotes = await sampleQuotes(adapter, setting, timestampMs);
      const twoSided = await recordQuotes(metricsContext, csv, setting, adapter.id, quotes, timestampMs);
      scoreboard.recordTwoSided(setting.id, adapter.id, twoSided);

      for (const intent of intents) {
        const result = await adapter.simulateTrade(intent);
        await recordTradeResult(
          runtime,
          metricsContext,
          csv,
          scoreboard,
          setting,
          adapter.id,
          result
        );
      }
    })
  );
}

async function recordTradeResult(
  runtime: MultiRunRuntimeConfig,
  metricsContext: ReturnType<MultiMetricsManager['context']>,
  csv: MultiCsvWriter,
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
  durationMs: number
): FlowEngine {
  const options: FlowEngineOptions = {
    settingId: setting.id,
    durationMs,
    routerTtlMs: setting.router.ttlSec * 1_000,
    routerSlippageBps: setting.router.slippageBps,
    startTimestampMs: startMs
  };
  return createFlowEngine(setting.flow, options);
}

async function prepareAdapters(
  config: MultiRunRuntimeConfig,
  setting: RunSettingDefinition,
  benchmarks: readonly BenchmarkId[]
): Promise<PreparedTickResources> {
  if (isChainBackedConfig(config.baseConfig) && config.chainConfig) {
    return prepareChainAdapters(config.chainConfig, config, setting, benchmarks);
  }
  if (!isChainBackedConfig(config.baseConfig)) {
    return prepareMockAdapters(config.baseConfig, config, setting, benchmarks);
  }
  throw new Error('Unsupported configuration for multi-run execution');
}

async function prepareChainAdapters(
  chainConfig: ChainBackedConfig,
  runtime: MultiRunRuntimeConfig,
  setting: RunSettingDefinition,
  benchmarks: readonly BenchmarkId[]
): Promise<PreparedTickResources> {
  const chainClient = createLiveChainClient(chainConfig);
  const poolClient = new LivePoolClient(chainConfig, chainClient);
  const oracleReader = new LiveOracleReader(chainConfig, chainClient);
  const initialState = await poolClient.getState();
  if (runtime.runtime.mode === 'mock') {
    throw new Error('Expected live or fork runtime for chain adapters');
  }
  const chainRuntime = runtime.runtime as ChainRuntimeConfig;

  const adapters: BenchmarkAdapter[] = [];
  for (const benchmark of benchmarks) {
    switch (benchmark) {
      case 'dnmm': {
        const adapter = new DnmmBenchmarkAdapter({
          chain: chainRuntime,
          poolClient,
          oracleReader,
          setting,
          baseConfig: runtime.baseConfig
        });
        await adapter.init();
        adapters.push(adapter);
        break;
      }
      case 'cpmm': {
        const adapter = new CpmmBenchmarkAdapter({
          baseDecimals: chainConfig.baseDecimals,
          quoteDecimals: chainConfig.quoteDecimals,
          baseReserves: initialState.baseReserves,
          quoteReserves: initialState.quoteReserves,
          feeBps: setting.comparator?.cpmm?.feeBps
        });
        await adapter.init();
        adapters.push(adapter);
        break;
      }
      case 'stableswap': {
        const adapter = new StableSwapBenchmarkAdapter({
          baseDecimals: chainConfig.baseDecimals,
          quoteDecimals: chainConfig.quoteDecimals,
          baseReserves: initialState.baseReserves,
          quoteReserves: initialState.quoteReserves,
          feeBps: setting.comparator?.stableswap?.feeBps,
          amplification: setting.comparator?.stableswap?.amplification
        });
        await adapter.init();
        adapters.push(adapter);
        break;
      }
      default:
        break;
    }
  }

  return {
    adapters,
    fetchOracle: () => oracleReader.sample(),
    fetchPoolState: () => poolClient.getState(),
    cleanup: () => chainClient.close()
  };
}

async function prepareMockAdapters(
  mockConfig: MockShadowBotConfig,
  runtime: MultiRunRuntimeConfig,
  setting: RunSettingDefinition,
  benchmarks: readonly BenchmarkId[]
): Promise<PreparedTickResources> {
  const poolClient = new SimPoolClient({
    baseDecimals: mockConfig.baseDecimals,
    quoteDecimals: mockConfig.quoteDecimals
  });
  const oracleReader = new SimOracleReader();

  const adapters: BenchmarkAdapter[] = [];
  const placeholderChain: ChainRuntimeConfig = {
    mode: 'live',
    rpcUrl: 'mock://',
    poolAddress: '0x0',
    baseTokenAddress: '0x0',
    quoteTokenAddress: '0x0',
    baseDecimals: mockConfig.baseDecimals,
    quoteDecimals: mockConfig.quoteDecimals,
    hcPxPrecompile: '0x0',
    hcBboPrecompile: '0x0',
    hcPxKey: 0,
    hcBboKey: 0,
    hcMarketType: 'spot',
    hcSizeDecimals: 2,
    hcPxMultiplier: 10n ** 18n
  };

  for (const benchmark of benchmarks) {
    switch (benchmark) {
      case 'dnmm': {
        const adapter = new DnmmBenchmarkAdapter({
          chain: placeholderChain,
          poolClient,
          oracleReader,
          setting,
          baseConfig: runtime.baseConfig
        });
        await adapter.init();
        adapters.push(adapter);
        break;
      }
      case 'cpmm': {
        const state = await poolClient.getState();
        const adapter = new CpmmBenchmarkAdapter({
          baseDecimals: mockConfig.baseDecimals,
          quoteDecimals: mockConfig.quoteDecimals,
          baseReserves: state.baseReserves,
          quoteReserves: state.quoteReserves,
          feeBps: setting.comparator?.cpmm?.feeBps
        });
        await adapter.init();
        adapters.push(adapter);
        break;
      }
      case 'stableswap': {
        const state = await poolClient.getState();
        const adapter = new StableSwapBenchmarkAdapter({
          baseDecimals: mockConfig.baseDecimals,
          quoteDecimals: mockConfig.quoteDecimals,
          baseReserves: state.baseReserves,
          quoteReserves: state.quoteReserves,
          feeBps: setting.comparator?.stableswap?.feeBps,
          amplification: setting.comparator?.stableswap?.amplification
        });
        await adapter.init();
        adapters.push(adapter);
        break;
      }
      default:
        break;
    }
  }

  return {
    adapters,
    fetchOracle: () => oracleReader.sample(),
    fetchPoolState: () => poolClient.getState(),
    cleanup: async () => {}
  };
}

async function sampleQuotes(
  adapter: BenchmarkAdapter,
  setting: RunSettingDefinition,
  timestampMs: number
): Promise<{ baseIn: BenchmarkQuoteSample; quoteIn: BenchmarkQuoteSample }> {
  const baseSize = Math.max(setting.flow.size.min, 1);
  const sizeWad = BigInt(Math.round(baseSize * 1e6)) * 10n ** 12n;
  const [baseIn, quoteIn] = await Promise.all([
    adapter.sampleQuote('base_in', sizeWad),
    adapter.sampleQuote('quote_in', sizeWad)
  ]);
  return {
    baseIn: { ...baseIn, timestampMs },
    quoteIn: { ...quoteIn, timestampMs }
  };
}

async function recordQuotes(
  metricsContext: ReturnType<MultiMetricsManager['context']>,
  csv: MultiCsvWriter,
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

function tradeResultToCsv(settingId: string, benchmark: BenchmarkId, result: BenchmarkTradeResult): TradeCsvRecord {
  const tsIso = new Date(result.intent.timestampMs).toISOString();
  const intentSizeFallback = result.intent.amountIn !== undefined ? String(result.intent.amountIn) : '';
  const appliedSizeFallback = result.appliedAmountIn !== undefined ? result.appliedAmountIn.toString() : '';
  return {
    tsIso,
    settingId,
    benchmark,
    side: result.intent.side,
    intentSize: result.intentBaseSizeWad ? result.intentBaseSizeWad.toString() : intentSizeFallback,
    appliedSize: result.executedBaseSizeWad ? result.executedBaseSizeWad.toString() : appliedSizeFallback,
    isPartial: result.isPartial,
    amountIn: result.amountIn.toString(),
    amountOut: result.amountOut.toString(),
    midUsed: result.midUsed.toString(),
    feeBpsUsed: result.feeBpsUsed,
    feeLvrBps: result.feeLvrBps,
    rebateBps: result.rebateBps,
    feePaid: result.feePaid ? result.feePaid.toString() : undefined,
    feeLvrPaid: result.feeLvrPaid ? result.feeLvrPaid.toString() : undefined,
    rebatePaid: result.rebatePaid ? result.rebatePaid.toString() : undefined,
    floorBps: result.floorBps ?? 0,
    tiltBps: result.tiltBps ?? 0,
    aomqClamped: result.aomqClamped,
    floorEnforced: result.floorEnforced,
    aomqUsed: result.aomqUsed,
    success: result.success,
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
    intentSizeBaseWad: sample.sizeBaseWad.toString(),
    feeBps: sample.feeBps,
    feeLvrBps: sample.feeLvrBps,
    rebateBps: sample.rebateBps,
    floorBps: sample.floorBps,
    ttlMs: sample.ttlMs,
    minOut: sample.minOut?.toString(),
    aomqFlags: sample.aomqFlags,
    mid: sample.mid.toString(),
    spreadBps: sample.spreadBps,
    confBps: sample.confBps,
    aomqActive: sample.aomqActive
  };
}

async function executeWithConcurrency<T>(tasks: readonly (() => Promise<T>)[], limit: number): Promise<T[]> {
  if (tasks.length === 0) return [];
  const results: T[] = new Array(tasks.length);
  let cursor = 0;
  const workers = new Array(Math.max(1, Math.min(limit, tasks.length))).fill(null).map(async () => {
    while (true) {
      const current = cursor;
      cursor += 1;
      if (current >= tasks.length) break;
      const value = await tasks[current]();
      results[current] = value;
    }
  });
  await Promise.all(workers);
  return results;
}
