import fs from 'fs/promises';
import path from 'path';
import {
  BENCHMARK_IDS,
  BenchmarkId,
  FlowPatternConfig,
  FlowPatternId,
  FlowSizeDistribution,
  FlowSizeDistributionKind,
  FlowToxicityConfig,
  LatencyProfile,
  MultiRunRuntimeConfig,
  RunAomqParams,
  RunFeatureFlags,
  RunInventoryParams,
  RunMakerParams,
  RunComparatorParams,
  RunRebateParams,
  RunSettingDefinition,
  RunnerPaths,
  SettingsFileSchema,
  ShadowBotConfig,
  RouterConfig,
  isChainBackedConfig,
  RuntimeChainConfig,
  ChainRuntimeConfig,
  MockRuntimeConfig,
  ChainBackedConfig,
  MockShadowBotConfig,
  SettingSweepDefinition,
  RiskScenarioDefinition,
  TradeFlowDefinition
} from './types.js';
import { loadConfig } from './config.js';

interface CliOptions {
  readonly runId?: string;
  readonly settingsPath?: string;
  readonly durationSec?: number;
  readonly maxParallel?: number;
  readonly seedBase?: number;
  readonly benchmarks?: string[];
  readonly persistCsv?: boolean;
  readonly promPort?: number;
  readonly logLevel?: 'info' | 'debug';
  readonly runRoot?: string;
}

const DEFAULT_SETTINGS_PATH = path.resolve(process.cwd(), 'settings/hype_settings.json');
const DEFAULT_METRICS_ROOT = path.resolve(process.cwd(), 'metrics/hype-metrics');
const DEFAULT_MAX_PARALLEL = 6;
const DEFAULT_SEED_BASE = 1_337;

export async function loadMultiRunConfig(
  argv: readonly string[] = process.argv.slice(2),
  env: NodeJS.ProcessEnv = process.env
): Promise<MultiRunRuntimeConfig> {
  const cli = parseCliOptions(argv);
  const baseConfig = await loadConfig();

  const runId = sanitizeRunId(cli.runId ?? env.RUN_ID ?? defaultRunId());
  const settingsPath = path.resolve(
    cli.settingsPath ?? env.SETTINGS_FILE ?? DEFAULT_SETTINGS_PATH
  );
  const settings = await loadSettingsFile(settingsPath);
  const sweeps = (settings.settings ?? []).map((entry, index) => normalizeSettingSweep(entry, index));
  const baseRuns = (settings.runs ?? []).map((run, index) => normalizeRunSetting(run, index));
  if (baseRuns.length === 0) {
    throw new Error('settings file must define at least one run template in `runs`');
  }
  const runs = expandRunsWithSweeps(baseRuns, sweeps);
  ensureUniqueRunIds(runs);
  if (runs.length === 0) {
    throw new Error('no runs generated after applying settings sweeps');
  }

  const benchmarks = resolveBenchmarks(
    cli.benchmarks ?? parseBenchmarksEnv(env.BENCHMARKS),
    settings.benchmarks
  );

  let chainConfig: ChainBackedConfig | undefined;
  let mockConfig: MockShadowBotConfig | undefined;
  if (isChainBackedConfig(baseConfig)) {
    chainConfig = baseConfig;
  } else {
    mockConfig = baseConfig;
  }

  const promPort = cli.promPort ?? parseOptionalInt(env.PROM_PORT) ?? baseConfig.promPort;
  const maxParallel = cli.maxParallel ?? parseOptionalInt(env.MAX_PARALLEL) ?? DEFAULT_MAX_PARALLEL;
  const seedBase = cli.seedBase ?? parseOptionalInt(env.SEED_BASE) ?? DEFAULT_SEED_BASE;
  const durationOverrideSec = cli.durationSec ?? parseOptionalInt(env.DURATION_SEC);
  const persistCsv = cli.persistCsv ?? parseOptionalBoolean(env.PERSIST_CSV) ?? true;
  const logLevel = cli.logLevel ?? parseLogLevel(env.LOG_LEVEL) ?? baseConfig.logLevel;

  const metricsRoot = path.resolve(
    cli.runRoot ?? env.METRICS_ROOT ?? DEFAULT_METRICS_ROOT
  );
  const paths = buildRunnerPaths(metricsRoot, runId);
  const checkpointMinutes = parseOptionalInt(env.CHECKPOINT_MINUTES) ?? 30;

  const riskScenarios = (settings.riskScenarios ?? []).map((scenario, index) =>
    normalizeRiskScenario(scenario, index)
  );
  const tradeFlows = (settings.tradeFlows ?? []).map((flow, index) =>
    normalizeTradeFlowDefinition(flow, index)
  );

  const runtime = extractRuntime(baseConfig);

  return {
    runId,
    baseConfig,
    chainConfig,
    mockConfig,
    logLevel,
    benchmarks,
    maxParallel,
    persistCsv,
    promPort,
    seedBase,
    durationOverrideSec,
    checkpointMinutes,
    pairLabels: baseConfig.labels,
    settings,
    runs,
    settingsConfig: sweeps,
    riskScenarios,
    tradeFlows,
    paths,
    runtime,
    addressBookPath: isChainBackedConfig(baseConfig) ? baseConfig.addressBookSource : undefined
  };
}

function parseCliOptions(argv: readonly string[]): CliOptions {
  const options: Record<string, unknown> = {};
  let index = 0;
  while (index < argv.length) {
    const arg = argv[index];
    if (!arg.startsWith('--')) {
      index += 1;
      continue;
    }
    const [flag, valuePart] = arg.split('=');
    const key = flag.slice(2);
    let value: string | undefined = valuePart;
    if (!value && index + 1 < argv.length && !argv[index + 1].startsWith('--')) {
      value = argv[index + 1];
      index += 1;
    }
    switch (key) {
      case 'run-id':
        options.runId = value;
        break;
      case 'settings':
        options.settingsPath = value;
        break;
      case 'duration-sec':
        options.durationSec = value ? parseIntStrict(value, 'duration-sec') : undefined;
        break;
      case 'max-parallel':
        options.maxParallel = value ? parseIntStrict(value, 'max-parallel') : undefined;
        break;
      case 'seed-base':
        options.seedBase = value ? parseIntStrict(value, 'seed-base') : undefined;
        break;
      case 'benchmarks':
        options.benchmarks = value
          ? value.split(',').map((entry) => entry.trim()).filter(Boolean)
          : [];
        break;
      case 'persist-csv':
        options.persistCsv = value ? parseBoolean(value) : true;
        break;
      case 'no-persist-csv':
        options.persistCsv = false;
        break;
      case 'prom-port':
        options.promPort = value ? parseIntStrict(value, 'prom-port') : undefined;
        break;
      case 'log-level':
        options.logLevel = parseLogLevel(value);
        break;
      case 'run-root':
        options.runRoot = value;
        break;
      default:
        break;
    }
    index += 1;
  }
  return options as CliOptions;
}

async function loadSettingsFile(settingsPath: string): Promise<SettingsFileSchema> {
  try {
    const contents = await fs.readFile(settingsPath, 'utf8');
    const parsed = JSON.parse(contents) as SettingsFileSchema;
    if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.runs)) {
      throw new Error('settings file must contain a non-empty runs array');
    }
    if (parsed.runs.length === 0) {
      throw new Error('settings file has empty runs array');
    }
    return parsed;
  } catch (error) {
    throw new Error(`Failed to load settings file at ${settingsPath}: ${(error as Error).message}`);
  }
}

function resolveBenchmarks(
  cli: string[] | undefined,
  fromSettings: readonly string[] | undefined
): BenchmarkId[] {
  const source = cli && cli.length > 0 ? cli : fromSettings ?? [];
  if (source.length === 0) {
    return ['dnmm'];
  }
  return source.map((entry) => {
    const normalized = entry.toLowerCase() as BenchmarkId;
    if (!BENCHMARK_IDS.includes(normalized)) {
      throw new Error(`Unsupported benchmark: ${entry}`);
    }
    return normalized;
  });
}

function buildRunnerPaths(root: string, runId: string): RunnerPaths {
  const runRoot = path.join(root, `run_${runId}`);
  return {
    runRoot,
    tradesDir: path.join(runRoot, 'trades'),
    quotesDir: path.join(runRoot, 'quotes'),
    scoreboardPath: path.join(runRoot, 'scoreboard.csv')
  };
}

function ensureUniqueRunIds(runs: readonly RunSettingDefinition[]): void {
  const ids = new Set<string>();
  for (const run of runs) {
    if (ids.has(run.id)) {
      throw new Error(`Duplicate run id detected: ${run.id}`);
    }
    ids.add(run.id);
  }
}

function normalizeRunSetting(raw: unknown, index: number): RunSettingDefinition {
  const record = expectRecord(raw, `runs[${index}]`);
  const id = requireString(record.id, `runs[${index}].id`);
  const label = requireString(record.label, `runs[${index}].label`);
  const featureFlags = normalizeFeatureFlags(record.featureFlags, index);
  const makerParams = normalizeMakerParams(record.makerParams, index);
  const inventoryParams = normalizeInventoryParams(record.inventoryParams, index);
  const aomqParams = normalizeAomqParams(record.aomqParams, index);
  const flow = normalizeFlow(record.flow, index);
  const latency = normalizeLatency(record.latency, index);
  const router = normalizeRouter(record.router, index);
  const sweepIds = normalizeOptionalStringArray(
    record.settingIds ?? record.settings ?? record.sweeps,
    `runs[${index}].settings`
  );
  return {
    id,
    label,
    settingSweepIds: sweepIds,
    featureFlags,
    makerParams,
    inventoryParams,
    aomqParams,
    flow,
    latency,
    router
  };
}

function normalizeOptionalStringArray(raw: unknown, pointer: string): string[] | undefined {
  if (raw === undefined || raw === null) {
    return undefined;
  }
  if (!Array.isArray(raw)) {
    throw new Error(`${pointer} must be an array of strings when provided`);
  }
  return raw.map((entry, idx) => requireString(entry, `${pointer}[${idx}]`));
}

function normalizeSettingSweep(raw: unknown, index: number): SettingSweepDefinition {
  const record = expectRecord(raw, `settings[${index}]`);
  const id = requireString(record.id, `settings[${index}].id`);
  const label = record.label ? requireString(record.label, `settings[${index}].label`) : undefined;
  const enableLvrFee = record.enableLvrFee === undefined ? undefined : parseBoolean(record.enableLvrFee);
  const enableAOMQ = record.enableAOMQ === undefined ? undefined : parseBoolean(record.enableAOMQ);
  const enableRebates =
    record.enableRebates === undefined ? undefined : parseBoolean(record.enableRebates);
  const kappaLvrBps = record.kappaLvrBps === undefined
    ? undefined
    : toNumber(record.kappaLvrBps, `settings[${index}].kappaLvrBps`);
  const maker = record.maker ? normalizeSweepMaker(record.maker, index) : undefined;
  const comparator = record.comparator ? normalizeSweepComparator(record.comparator, index) : undefined;
  const rebates = record.rebates ? normalizeSweepRebates(record.rebates, index) : undefined;
  return {
    id,
    label,
    enableLvrFee,
    enableAOMQ,
    enableRebates,
    kappaLvrBps,
    maker,
    comparator,
    rebates
  };
}

function normalizeSweepMaker(raw: unknown, index: number): Partial<RunMakerParams> {
  const record = expectRecord(raw, `settings[${index}].maker`);
  const ttlMs =
    record.ttlMs !== undefined || record.ttl_ms !== undefined
      ? toNumber(record.ttlMs ?? record.ttl_ms, `settings[${index}].maker.ttlMs`)
      : undefined;
  const alphaBboBps =
    record.alphaBboBps !== undefined
      ? toNumber(record.alphaBboBps, `settings[${index}].maker.alphaBboBps`)
      : undefined;
  const betaFloorBps =
    record.betaFloorBps !== undefined
      ? toNumber(record.betaFloorBps, `settings[${index}].maker.betaFloorBps`)
      : undefined;
  const s0Notional =
    record.S0Notional !== undefined || record.s0Notional !== undefined
      ? toNumber(record.S0Notional ?? record.s0Notional, `settings[${index}].maker.S0Notional`)
      : undefined;
  return {
    ...(ttlMs !== undefined ? { ttlMs } : {}),
    ...(alphaBboBps !== undefined ? { alphaBboBps } : {}),
    ...(betaFloorBps !== undefined ? { betaFloorBps } : {}),
    ...(s0Notional !== undefined ? { S0Notional: s0Notional } : {})
  };
}

function normalizeSweepComparator(raw: unknown, index: number): RunComparatorParams {
  const record = expectRecord(raw, `settings[${index}].comparator`);
  const cpmm = record.cpmm
    ? (() => {
        const cpmmRecord = expectRecord(record.cpmm, `settings[${index}].comparator.cpmm`);
        return {
          feeBps: toNumber(
            cpmmRecord.feeBps ?? cpmmRecord.fee_bps,
            `settings[${index}].comparator.cpmm.feeBps`
          )
        };
      })()
    : undefined;
  const stableswap = record.stableswap
    ? (() => {
        const ssRecord = expectRecord(record.stableswap, `settings[${index}].comparator.stableswap`);
        return {
          feeBps: toNumber(
            ssRecord.feeBps ?? ssRecord.fee_bps,
            `settings[${index}].comparator.stableswap.feeBps`
          ),
          amplification: toNumber(
            ssRecord.amplification ?? ssRecord.A ?? ssRecord.a,
            `settings[${index}].comparator.stableswap.amplification`
          )
        };
      })()
    : undefined;
  return {
    ...(cpmm ? { cpmm } : {}),
    ...(stableswap ? { stableswap } : {})
  };
}

function normalizeSweepRebates(raw: unknown, index: number): RunRebateParams {
  const record = expectRecord(raw, `settings[${index}].rebates`);
  const allowlist = normalizeOptionalStringArray(record.allowlist, `settings[${index}].rebates.allowlist`);
  const bps = record.bps === undefined ? 0 : toNumber(record.bps, `settings[${index}].rebates.bps`);
  return {
    allowlist: allowlist ?? [],
    bps
  };
}

function expandRunsWithSweeps(
  baseRuns: readonly RunSettingDefinition[],
  sweeps: readonly SettingSweepDefinition[]
): RunSettingDefinition[] {
  if (sweeps.length === 0) {
    return [...baseRuns];
  }
  const sweepMap = new Map<string, SettingSweepDefinition>();
  for (const sweep of sweeps) {
    if (sweepMap.has(sweep.id)) {
      throw new Error(`Duplicate settings sweep id detected: ${sweep.id}`);
    }
    sweepMap.set(sweep.id, sweep);
  }
  const results: RunSettingDefinition[] = [];
  for (const run of baseRuns) {
    const targetSweeps = run.settingSweepIds && run.settingSweepIds.length > 0
      ? run.settingSweepIds
      : sweeps.map((s) => s.id);
    if (targetSweeps.length === 0) {
      results.push(run);
      continue;
    }
    for (const sweepId of targetSweeps) {
      const sweep = sweepMap.get(sweepId);
      if (!sweep) {
        throw new Error(`Run ${run.id} references unknown setting sweep '${sweepId}'`);
      }
      const featureFlags: RunFeatureFlags = {
        ...run.featureFlags,
        ...(sweep.enableAOMQ !== undefined ? { enableAOMQ: sweep.enableAOMQ } : {}),
        ...(sweep.enableRebates !== undefined ? { enableRebates: sweep.enableRebates } : {}),
        ...(sweep.enableLvrFee !== undefined ? { enableLvrFee: sweep.enableLvrFee } : {})
      };
      const makerParams: RunMakerParams = {
        ...run.makerParams,
        ...(sweep.maker?.ttlMs !== undefined ? { ttlMs: sweep.maker.ttlMs } : {}),
        ...(sweep.maker?.alphaBboBps !== undefined ? { alphaBboBps: sweep.maker.alphaBboBps } : {}),
        ...(sweep.maker?.betaFloorBps !== undefined ? { betaFloorBps: sweep.maker.betaFloorBps } : {}),
        ...(sweep.maker?.S0Notional !== undefined ? { S0Notional: sweep.maker.S0Notional } : {})
      };
      const fee = {
        ...(run.fee ?? {}),
        ...(sweep.kappaLvrBps !== undefined ? { kappaLvrBps: sweep.kappaLvrBps } : {})
      };
      const rebates: RunRebateParams | undefined = (() => {
        if (!sweep.rebates && !run.rebates) {
          return undefined;
        }
        const allowlist = sweep.rebates?.allowlist ?? run.rebates?.allowlist ?? [];
        const bps = sweep.rebates?.bps ?? run.rebates?.bps ?? 0;
        return { allowlist, bps };
      })();
      const comparator: RunComparatorParams | undefined = (() => {
        if (!sweep.comparator && !run.comparator) return run.comparator;
        return {
          ...(run.comparator ?? {}),
          ...(sweep.comparator ?? {})
        };
      })();
      const expanded: RunSettingDefinition = {
        ...run,
        id: `${run.id}__${sweep.id}`,
        label: `${run.label} :: ${sweep.label ?? sweep.id}`,
        sweepId: sweep.id,
        featureFlags,
        makerParams,
        fee,
        rebates,
        comparator,
        settingSweepIds: undefined
      };
      results.push(expanded);
    }
  }
  return results;
}

function normalizeRiskScenario(raw: unknown, index: number): RiskScenarioDefinition {
  const record = expectRecord(raw, `riskScenarios[${index}]`);
  const id = requireString(record.id, `riskScenarios[${index}].id`);
  const bboSpread = record.bbo_spread_bps
    ? normalizeRange(record.bbo_spread_bps, `riskScenarios[${index}].bbo_spread_bps`)
    : undefined;
  const sigma = record.sigma_bps
    ? normalizeRange(record.sigma_bps, `riskScenarios[${index}].sigma_bps`)
    : undefined;
  const outage = record.pyth_outages
    ? (() => {
        const outageRecord = expectRecord(record.pyth_outages, `riskScenarios[${index}].pyth_outages`);
        return {
          bursts: toNumber(outageRecord.bursts, `riskScenarios[${index}].pyth_outages.bursts`),
          secsEach: toNumber(
            outageRecord.secs_each ?? outageRecord.secsEach,
            `riskScenarios[${index}].pyth_outages.secs_each`
          )
        };
      })()
    : undefined;
  const pythDropRate = record.pyth_drop_rate !== undefined ? Number(record.pyth_drop_rate) : undefined;
  const durationMin = record.duration_min !== undefined ? Number(record.duration_min) : undefined;
  const autopauseExpected =
    record.autopause_expected !== undefined ? parseBoolean(record.autopause_expected) : undefined;
  const quoteLatency =
    record.quote_latency_ms !== undefined
      ? toNumber(record.quote_latency_ms, `riskScenarios[${index}].quote_latency_ms`)
      : undefined;
  const ttlExpiryRate =
    record.ttl_expiry_rate_target !== undefined ? Number(record.ttl_expiry_rate_target) : undefined;
  const spreadShift =
    record.bbo_spread_bps_shift !== undefined
      ? requireString(record.bbo_spread_bps_shift, `riskScenarios[${index}].bbo_spread_bps_shift`)
      : undefined;
  return {
    id,
    ...(bboSpread ? { bboSpreadBps: bboSpread } : {}),
    ...(sigma ? { sigmaBps: sigma } : {}),
    ...(outage ? { pythOutages: outage } : {}),
    ...(pythDropRate !== undefined ? { pythDropRate } : {}),
    ...(durationMin !== undefined ? { durationMin } : {}),
    ...(autopauseExpected !== undefined ? { autopauseExpected } : {}),
    ...(quoteLatency !== undefined ? { quoteLatencyMs: quoteLatency } : {}),
    ...(ttlExpiryRate !== undefined ? { ttlExpiryRateTarget: ttlExpiryRate } : {}),
    ...(spreadShift ? { bboSpreadBpsShift: spreadShift } : {})
  };
}

function normalizeRange(raw: unknown, pointer: string): [number, number] {
  if (!Array.isArray(raw) || raw.length !== 2) {
    throw new Error(`${pointer} must be a two-element array`);
  }
  return [toNumber(raw[0], `${pointer}[0]`), toNumber(raw[1], `${pointer}[1]`)];
}

function normalizeTradeFlowDefinition(raw: unknown, index: number): TradeFlowDefinition {
  const record = expectRecord(raw, `tradeFlows[${index}]`);
  const id = requireString(record.id, `tradeFlows[${index}].id`);
  const sizeDist = requireString(record.size_dist ?? record.sizeDist, `tradeFlows[${index}].size_dist`);
  const medianBase = record.median_base
    ? requireString(record.median_base, `tradeFlows[${index}].median_base`)
    : undefined;
  const heavyTail = record.heavytail !== undefined ? parseBoolean(record.heavytail) : undefined;
  const modes = record.modes ? normalizeOptionalStringArray(record.modes, `tradeFlows[${index}].modes`) : undefined;
  const share = record.share
    ? Object.fromEntries(
        Object.entries(expectRecord(record.share, `tradeFlows[${index}].share`)).map(([key, value]) => [
          key,
          Number(value)
        ])
      )
    : undefined;
  const spikeSizes = record.spike_sizes
    ? normalizeOptionalStringArray(record.spike_sizes, `tradeFlows[${index}].spike_sizes`)
    : undefined;
  const intervalMin = record.interval_min !== undefined ? Number(record.interval_min) : undefined;
  const sizeParams = record.size_params ? (record.size_params as Record<string, unknown>) : undefined;
  const pattern = record.pattern
    ? (() => {
        const candidate = requireString(record.pattern, `tradeFlows[${index}].pattern`).toLowerCase();
        if (!isFlowPattern(candidate)) {
          throw new Error(`tradeFlows[${index}].pattern must be a supported flow pattern`);
        }
        return candidate as FlowPatternId;
      })()
    : undefined;
  return {
    id,
    sizeDist,
    ...(medianBase ? { medianBase } : {}),
    ...(heavyTail !== undefined ? { heavyTail } : {}),
    ...(modes ? { modes } : {}),
    ...(share ? { share } : {}),
    ...(spikeSizes ? { spikeSizes } : {}),
    ...(intervalMin !== undefined ? { intervalMin } : {}),
    ...(sizeParams ? { sizeParams } : {}),
    ...(pattern ? { pattern } : {})
  };
}

function normalizeFeatureFlags(raw: unknown, index: number): RunFeatureFlags {
  const record = expectRecord(raw, `runs[${index}].featureFlags`);
  return {
    enableSoftDivergence: parseBoolean(record.enableSoftDivergence ?? true),
    enableSizeFee: parseBoolean(record.enableSizeFee ?? false),
    enableBboFloor: parseBoolean(record.enableBboFloor ?? true),
    enableInvTilt: parseBoolean(record.enableInvTilt ?? true),
    enableAOMQ: parseBoolean(record.enableAOMQ ?? false),
    enableRebates: parseBoolean(record.enableRebates ?? false),
    enableLvrFee: parseBoolean(record.enableLvrFee ?? false)
  };
}

function normalizeMakerParams(raw: unknown, index: number): RunMakerParams {
  const record = expectRecord(raw, `runs[${index}].makerParams`);
  return {
    betaFloorBps: toNumber(record.betaFloorBps, `runs[${index}].makerParams.betaFloorBps`),
    alphaBboBps: toNumber(record.alphaBboBps, `runs[${index}].makerParams.alphaBboBps`),
    S0Notional: toNumber(
      record.S0Notional ?? record.s0Notional,
      `runs[${index}].makerParams.S0Notional`
    ),
    ttlMs: toNumber(record.ttlMs ?? record.ttl_ms ?? 1_000, `runs[${index}].makerParams.ttlMs`)
  };
}

function normalizeInventoryParams(raw: unknown, index: number): RunInventoryParams {
  const record = expectRecord(raw, `runs[${index}].inventoryParams`);
  return {
    invTiltBpsPer1pct: toNumber(
      record.invTiltBpsPer1pct,
      `runs[${index}].inventoryParams.invTiltBpsPer1pct`
    ),
    invTiltMaxBps: toNumber(
      record.invTiltMaxBps,
      `runs[${index}].inventoryParams.invTiltMaxBps`
    ),
    tiltConfWeightBps: toNumber(
      record.tiltConfWeightBps,
      `runs[${index}].inventoryParams.tiltConfWeightBps`
    ),
    tiltSpreadWeightBps: toNumber(
      record.tiltSpreadWeightBps,
      `runs[${index}].inventoryParams.tiltSpreadWeightBps`
    )
  };
}

function normalizeAomqParams(raw: unknown, index: number): RunAomqParams {
  const record = expectRecord(raw, `runs[${index}].aomqParams`);
  return {
    minQuoteNotional: toNumber(
      record.minQuoteNotional,
      `runs[${index}].aomqParams.minQuoteNotional`
    ),
    emergencySpreadBps: toNumber(
      record.emergencySpreadBps,
      `runs[${index}].aomqParams.emergencySpreadBps`
    ),
    floorEpsilonBps: toNumber(
      record.floorEpsilonBps,
      `runs[${index}].aomqParams.floorEpsilonBps`
    )
  };
}

function normalizeFlow(raw: unknown, index: number): FlowPatternConfig {
  const record = expectRecord(raw, `runs[${index}].flow`);
  const patternRaw = requireString(record.pattern, `runs[${index}].flow.pattern`).toLowerCase();
  if (!isFlowPattern(patternRaw)) {
    throw new Error(`Unsupported flow pattern: ${patternRaw}`);
  }
  const seconds = toNumber(record.seconds, `runs[${index}].flow.seconds`);
  const seed = toNumber(record.seed, `runs[${index}].flow.seed`);
  const txnRatePerMin = toNumber(
    record.txn_rate_per_min ?? record.txnRatePerMin,
    `runs[${index}].flow.txn_rate_per_min`
  );
  const sizeKind = (record.size_dist ?? record.sizeDist ?? 'lognormal') as FlowSizeDistributionKind;
  const size = normalizeFlowSize(sizeKind, record.size_params ?? record.sizeParams, index);
  const toxicity = record.toxicity ? normalizeToxicity(record.toxicity, index) : undefined;
  return {
    pattern: patternRaw,
    seconds,
    seed,
    txnRatePerMin,
    size,
    toxicity
  };
}

function normalizeFlowSize(
  kindRaw: FlowSizeDistributionKind,
  paramsRaw: unknown,
  index: number
): FlowSizeDistribution {
  const kind = (kindRaw ?? 'lognormal').toLowerCase() as FlowSizeDistributionKind;
  const params = expectRecord(paramsRaw, `runs[${index}].flow.size_params`);
  const min = toNumber(params.min, `runs[${index}].flow.size_params.min`);
  const max = toNumber(params.max ?? params.min, `runs[${index}].flow.size_params.max`);
  if (kind === 'lognormal') {
    return {
      kind,
      mu: toNumber(params.mu, `runs[${index}].flow.size_params.mu`),
      sigma: toNumber(params.sigma, `runs[${index}].flow.size_params.sigma`),
      min,
      max
    };
  }
  if (kind === 'pareto') {
    return {
      kind,
      mu: toNumber(params.mu, `runs[${index}].flow.size_params.mu`),
      sigma: toNumber(
        params.sigma ?? params.alpha ?? 1,
        `runs[${index}].flow.size_params.sigma`
      ),
      min,
      max
    };
  }
  if (kind === 'fixed') {
    return {
      kind,
      min,
      max
    };
  }
  throw new Error(`Unsupported size distribution: ${kind}`);
}

function normalizeToxicity(raw: unknown, index: number): FlowToxicityConfig {
  const record = expectRecord(raw, `runs[${index}].flow.toxicity`);
  return {
    oracleLeadMs: toNumber(
      record.oracle_lead_ms ?? record.oracleLeadMs,
      `runs[${index}].flow.toxicity.oracle_lead_ms`
    ),
    edgeBpsMu: toNumber(
      record.edge_bps_mu ?? record.edgeBpsMu,
      `runs[${index}].flow.toxicity.edge_bps_mu`
    ),
    edgeBpsSigma: toNumber(
      record.edge_bps_sigma ?? record.edgeBpsSigma,
      `runs[${index}].flow.toxicity.edge_bps_sigma`
    )
  };
}

function normalizeLatency(raw: unknown, index: number): LatencyProfile {
  const record = expectRecord(raw, `runs[${index}].latency`);
  return {
    quoteToTxMs: toNumber(
      record.quote_to_tx_ms ?? record.quoteToTxMs,
      `runs[${index}].latency.quote_to_tx_ms`
    ),
    jitterMs: toNumber(record.jitter_ms ?? record.jitterMs, `runs[${index}].latency.jitter_ms`)
  };
}

function normalizeRouter(raw: unknown, index: number): RouterConfig {
  const record = expectRecord(raw, `runs[${index}].router`);
  const policyRaw = requireString(
    record.minOut_policy ?? record.minOutPolicy,
    `runs[${index}].router.minOut_policy`
  ).toLowerCase();
  if (!['preview', 'preview_ladder', 'fixed_margin'].includes(policyRaw)) {
    throw new Error(`Unsupported router policy: ${policyRaw}`);
  }
  return {
    slippageBps: toNumber(
      record.slippage_bps ?? record.slippageBps,
      `runs[${index}].router.slippage_bps`
    ),
    ttlSec: toNumber(record.ttl_sec ?? record.ttlSec, `runs[${index}].router.ttl_sec`),
    minOutPolicy: policyRaw as RouterConfig['minOutPolicy']
  };
}

function extractRuntime(config: ShadowBotConfig): RuntimeChainConfig {
  if (isChainBackedConfig(config)) {
    const chain: ChainRuntimeConfig = {
      mode: config.mode,
      rpcUrl: config.rpcUrl,
      wsUrl: config.wsUrl,
      chainId: config.chainId,
      poolAddress: config.poolAddress,
      baseTokenAddress: config.baseTokenAddress,
      quoteTokenAddress: config.quoteTokenAddress,
      baseDecimals: config.baseDecimals,
      quoteDecimals: config.quoteDecimals,
      pythAddress: config.pythAddress,
      hcPxPrecompile: config.hcPxPrecompile,
      hcBboPrecompile: config.hcBboPrecompile,
      hcPxKey: config.hcPxKey,
      hcBboKey: config.hcBboKey,
      hcMarketType: config.hcMarketType,
      hcSizeDecimals: config.hcSizeDecimals,
      hcPxMultiplier: config.hcPxMultiplier,
      pythPriceId: config.pythPriceId,
      gasPriceGwei: config.gasPriceGwei,
      nativeUsd: config.nativeUsd,
      addressBookSource: config.addressBookSource
    };
    return chain;
  }
  const mock: MockRuntimeConfig = { mode: 'mock' };
  return mock;
}

function expectRecord(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object') {
    throw new Error(`${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function requireString(value: unknown, label: string): string {
  if (typeof value === 'string' && value.trim().length > 0) {
    return value.trim();
  }
  throw new Error(`${label} must be a non-empty string`);
}

function toNumber(value: unknown, label: string): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const normalized = value.replace(/_/g, '');
    const parsed = Number(normalized);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  throw new Error(`${label} must be numeric`);
}

function parseBoolean(value: unknown): boolean {
  if (typeof value === 'boolean') return value;
  if (typeof value !== 'string') return false;
  const lowered = value.toLowerCase();
  return lowered === 'true' || lowered === '1' || lowered === 'yes';
}

function parseOptionalBoolean(value: string | undefined): boolean | undefined {
  if (value === undefined) return undefined;
  return parseBoolean(value);
}

function parseOptionalInt(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const parsed = Number.parseInt(value, 10);
  return Number.isNaN(parsed) ? undefined : parsed;
}

function parseIntStrict(value: string, label: string): number {
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`Unable to parse integer for ${label}: ${value}`);
  }
  return parsed;
}

function parseLogLevel(raw?: string | null): 'info' | 'debug' | undefined {
  if (!raw) return undefined;
  return raw.toLowerCase() === 'debug' ? 'debug' : 'info';
}

function parseBenchmarksEnv(raw?: string): string[] | undefined {
  if (!raw) return undefined;
  return raw
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);
}

function sanitizeRunId(runId: string): string {
  return runId.replace(/[^a-zA-Z0-9_-]/g, '-');
}

function defaultRunId(): string {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

function isFlowPattern(value: string): value is FlowPatternId {
  return (
    value === 'arb_constant' ||
    value === 'toxic' ||
    value === 'trend' ||
    value === 'mean_revert' ||
    value === 'benign_poisson' ||
    value === 'mixed'
  );
}
