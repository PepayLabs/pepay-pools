import 'dotenv/config';
import { Contract } from 'ethers';
import { loadConfig } from './config.js';
import { IDNM_POOL_ABI } from './abis.js';
import { createLiveChainClient, LiveChainClient } from './providers.js';
import { createNullChainClient } from './mock/mockChainClient.js';
import { LivePoolClient } from './poolClient.js';
import { MockPoolClient } from './mock/mockPool.js';
import { LiveOracleReader } from './oracleReader.js';
import { MockOracleReader } from './mock/mockOracle.js';
import { createScenarioEngine } from './mock/scenarios.js';
import { createMockClock, MockClock } from './mock/mockClock.js';
import { createMetricsManager, MetricsManager } from './metrics.js';
import { buildCsvRows, createCsvWriter } from './csvWriter.js';
import { runSyntheticProbes } from './probes.js';
import {
  ChainBackedConfig,
  ChainClient,
  LoopArtifacts,
  OracleReaderAdapter,
  PoolClientAdapter,
  ProbeQuote,
  RegimeFlag,
  RegimeFlags,
  REGIME_BIT_VALUES,
  ShadowBotConfig,
  isChainBackedConfig
} from './types.js';

interface Logger {
  level: 'info' | 'debug';
  info(message: string, meta?: Record<string, unknown>): void;
  debug(message: string, meta?: Record<string, unknown>): void;
  error(message: string, meta?: Record<string, unknown>): void;
}

const LEVEL_WEIGHT: Record<'debug' | 'info' | 'error', number> = {
  debug: 10,
  info: 20,
  error: 30
};

interface Clock {
  now(): number;
  nowSeconds(): number;
  sleep(ms: number): Promise<void>;
}

class SystemClock implements Clock {
  now(): number {
    return Date.now();
  }

  nowSeconds(): number {
    return Math.floor(Date.now() / 1000);
  }

  async sleep(ms: number): Promise<void> {
    if (ms <= 0) return;
    await new Promise<void>((resolve) => setTimeout(resolve, ms));
  }
}

function createLogger(level: 'info' | 'debug'): Logger {
  function shouldLog(target: 'debug' | 'info' | 'error'): boolean {
    return LEVEL_WEIGHT[target] >= LEVEL_WEIGHT[level];
  }

  function emit(target: 'debug' | 'info' | 'error', message: string, meta?: Record<string, unknown>) {
    if (!shouldLog(target)) return;
    const payload = {
      ts: new Date().toISOString(),
      level: target,
      msg: message,
      ...(meta ?? {})
    };
    const line = JSON.stringify(payload);
    if (target === 'error') {
      console.error(line);
    } else {
      console.log(line);
    }
  }

  return {
    level,
    info: (message, meta) => emit('info', message, meta),
    debug: (message, meta) => emit('debug', message, meta),
    error: (message, meta) => emit('error', message, meta)
  };
}

function aggregateRegimeFlags(probes: ProbeQuote[]): RegimeFlags {
  const flags = new Set<RegimeFlag>();
  for (const probe of probes) {
    probe.riskBits.forEach((flag) => flags.add(flag));
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

function probeRegimeLabel(probe: ProbeQuote): string {
  return probe.riskBits.length === 0 ? 'calm' : probe.riskBits.join('|');
}

function mergeQuoteResult(probe: ProbeQuote): 'ok' | 'fallback' | 'error' {
  if (!probe.success) return 'error';
  if (probe.usedFallback || probe.riskBits.includes('Fallback')) return 'fallback';
  return 'ok';
}

function detectTwoSided(probes: ProbeQuote[]): boolean {
  const baseIn = probes.some((probe) => probe.side === 'base_in' && probe.success);
  const quoteIn = probes.some((probe) => probe.side === 'quote_in' && probe.success);
  return baseIn && quoteIn;
}

async function setupEventSubscriptions(
  config: ChainBackedConfig,
  chainClient: LiveChainClient,
  metrics: MetricsManager,
  logger: Logger
): Promise<(() => Promise<void>) | undefined> {
  const ws = chainClient.getWebSocketProvider();
  if (!ws) {
    logger.info('ws.provider.unavailable', { note: 'Event subscriptions disabled' });
    return undefined;
  }

  const wsContract = new Contract(config.poolAddress, IDNM_POOL_ABI, ws);

  const recenterHandler = (_oldTarget: bigint, newTarget: bigint, mid: bigint) => {
    metrics.incrementRecenterCommit();
    metrics.setLastRebalancePrice(mid);
    logger.info('event.recenter', {
      newTarget: newTarget.toString(),
      midWad: mid.toString()
    });
  };

  const aomqHandler = (trigger: string, isBaseIn: boolean, amountIn: bigint, quoteNotional: bigint, spreadBps: number) => {
    metrics.incrementAomqClamp();
    logger.info('event.aomq', {
      trigger,
      isBaseIn,
      amountIn: amountIn.toString(),
      quoteNotional: quoteNotional.toString(),
      spreadBps
    });
  };

  wsContract.on('TargetBaseXstarUpdated', recenterHandler);
  wsContract.on('AomqActivated', aomqHandler);

  return async () => {
    wsContract.off('TargetBaseXstarUpdated', recenterHandler);
    wsContract.off('AomqActivated', aomqHandler);
  };
}

async function runLoop(
  config: ShadowBotConfig,
  clock: Clock,
  poolClient: PoolClientAdapter,
  metrics: MetricsManager,
  oracleReader: OracleReaderAdapter,
  logger: Logger,
  csvWriter: ReturnType<typeof createCsvWriter>
): Promise<void> {
  const poolConfig = await poolClient.getConfig();
  const state = await poolClient.getState();
  const oracle = await oracleReader.sample();

  if (oracle.hc.status === 'error' && oracle.hc.reason === 'PrecompileError') {
    metrics.incrementPrecompileError();
  }
  if (oracle.pyth && oracle.pyth.status === 'error' && oracle.pyth.reason === 'PythError') {
    logger.debug('oracle.pyth.error', { detail: oracle.pyth.statusDetail });
  }

  const probes = await runSyntheticProbes({
    poolClient,
    poolState: state,
    poolConfig,
    oracle,
    sizeGrid: config.sizeGrid
  });

  const combinedRegime = aggregateRegimeFlags(probes);

  metrics.recordPoolState(state);
  metrics.recordOracle(oracle);
  metrics.recordRegime(combinedRegime);

  probes.forEach((probe, index) => {
    const rung = Math.floor(index / 2);
    metrics.recordProbe(probe, rung, probeRegimeLabel(probe));
    const resultLabel = mergeQuoteResult(probe);
    metrics.recordQuoteResult(resultLabel);
    if (!probe.success) {
      if (probe.status === 'PreviewStale') {
        metrics.incrementPreviewStale();
      }
      if (probe.status === 'AOMQClamp') {
        metrics.incrementAomqClamp();
      }
      if (probe.status === 'PrecompileError') {
        metrics.incrementPrecompileError();
      }
    }
  });

  const timestampMs = clock.now();
  metrics.recordTwoSided(timestampMs, detectTwoSided(probes));

  const csvRows = buildCsvRows(probes, timestampMs, {
    midHc: oracle.hc.midWad,
    midPyth: oracle.pyth?.midWad,
    confBps: oracle.pyth?.confBps,
    spreadBps: oracle.hc.spreadBps
  });
  await csvWriter.appendRows(csvRows);

  const summary: LoopArtifacts = {
    oracle,
    poolState: state,
    probes,
    timestampMs
  };
  await csvWriter.writeSummary(summary);

  logger.debug('loop.metrics', {
    probes: probes.length,
    regime: combinedRegime.asArray.join('|') || 'calm'
  });
}

async function main(): Promise<void> {
  const config = await loadConfig();
  const logger = createLogger(config.logLevel);
  const metrics = createMetricsManager(config);
  let clock: Clock;
  let chainClient: ChainClient;
  let poolClient: PoolClientAdapter;
  let oracleReader: OracleReaderAdapter;
  let scenarioMeta: { name: string; source: string } | undefined;

  if (isChainBackedConfig(config)) {
    clock = new SystemClock();
    const liveClient = createLiveChainClient(config, (sample) => metrics.recordProviderSample(sample));
    chainClient = liveClient;
    poolClient = new LivePoolClient(config, liveClient);
    oracleReader = new LiveOracleReader(config, liveClient);
  } else {
    const mockClock = createMockClock();
    clock = mockClock;
    chainClient = createNullChainClient(mockClock);
    const { engine, definition, source } = await createScenarioEngine(
      config.scenarioName,
      mockClock.now(),
      config.scenarioFile
    );
    scenarioMeta = { name: definition.name, source };
    oracleReader = new MockOracleReader(engine, mockClock);
    poolClient = new MockPoolClient(engine, mockClock, config.baseDecimals, config.quoteDecimals, config.guaranteedMinOut);
  }

  const csvWriter = createCsvWriter(config, logger);

  await metrics.startServer();

  const tokens = await poolClient.getTokens();
  const poolConfig = await poolClient.getConfig();

  const initMeta: Record<string, unknown> = {
    labels: config.labels,
    sizes: config.sizeGrid.map((size) => size.toString()),
    mode: config.mode,
    tokens,
    featureFlags: poolConfig.featureFlags
  };
  if (isChainBackedConfig(config)) {
    initMeta.rpcUrl = config.rpcUrl;
    initMeta.pool = config.poolAddress;
  }
  if (scenarioMeta) {
    initMeta.scenario = scenarioMeta;
  }
  logger.info('shadowbot.init', initMeta);

  const unsubscribe = isChainBackedConfig(config)
    ? await setupEventSubscriptions(config, chainClient as LiveChainClient, metrics, logger)
    : undefined;

  let running = true;
  const signals: NodeJS.Signals[] = ['SIGINT', 'SIGTERM'];
  signals.forEach((signal) => {
    process.on(signal, () => {
      logger.info('signal.received', { signal });
      running = false;
    });
  });

  while (running) {
    const loopStarted = Date.now();
    try {
      await runLoop(config, clock, poolClient, metrics, oracleReader, logger, csvWriter);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      logger.error('loop.error', { detail });
    }
    const elapsed = Date.now() - loopStarted;
    const waitMs = Math.max(config.intervalMs - elapsed, 0);
    if (!running) break;
    if (waitMs > 0) {
      await clock.sleep(waitMs);
    }
  }

  if (unsubscribe) {
    await unsubscribe();
  }
  await metrics.stopServer();
  await chainClient.close();
  logger.info('shadowbot.stopped');
}

main().catch((error) => {
  const detail = error instanceof Error ? error.message : String(error);
  console.error(JSON.stringify({ ts: new Date().toISOString(), level: 'error', msg: 'fatal', detail }));
  process.exit(1);
});
