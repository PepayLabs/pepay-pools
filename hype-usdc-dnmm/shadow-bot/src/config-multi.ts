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
  MockShadowBotConfig
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
  const runs = settings.runs.map((run, index) => normalizeRunSetting(run, index));
  ensureUniqueRunIds(runs);

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
    pairLabels: baseConfig.labels,
    settings,
    runs,
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
  return {
    id,
    label,
    featureFlags,
    makerParams,
    inventoryParams,
    aomqParams,
    flow,
    latency,
    router
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
    enableRebates: parseBoolean(record.enableRebates ?? false)
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
    )
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
