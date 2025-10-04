import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';
import {
  AddressBookEntry,
  AddressBookFile,
  ChainRuntimeConfig,
  BenchmarkId,
  FlowPatternConfig,
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
  RouterConfig,
  SettingsFileSchema,
  ShadowBotLabels,
  ShadowBotMode
} from './types.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

interface CliOptions {
  readonly mode?: string;
  readonly runId?: string;
  readonly settings?: string;
  readonly durationSec?: number;
  readonly maxParallel?: number;
  readonly seedBase?: number;
  readonly benchmarks?: string[];
  readonly persistCsv?: boolean;
  readonly promPort?: number;
  readonly logLevel?: 'info' | 'debug';
  readonly runRoot?: string;
  readonly addressBook?: string;
}

const DEFAULT_SETTINGS_PATH = path.resolve(__dirname, './settings/hype_settings.json');
const DEFAULT_METRICS_ROOT = path.resolve(__dirname, '../metrics/hype-metrics');
const DEFAULT_PROM_PORT = 9_464;
const DEFAULT_MAX_PARALLEL = 6;
const DEFAULT_SEED_BASE = 1_337;
const DEFAULT_ADDRESS_BOOK = path.resolve(__dirname, 'address-book.json');

export async function loadConfig(
  argv = process.argv.slice(2),
  env: NodeJS.ProcessEnv = process.env
): Promise<MultiRunRuntimeConfig> {
  const cli = parseCliOptions(argv);
  const mode = resolveMode(cli.mode ?? env.MODE);
  const logLevel = resolveLogLevel(cli.logLevel ?? env.LOG_LEVEL);
  const runId = sanitizeRunId(cli.runId ?? env.RUN_ID ?? createDefaultRunId());

  const settingsPath = path.resolve(cli.settings ?? env.SETTINGS_FILE ?? DEFAULT_SETTINGS_PATH);
  const settings = await loadSettingsFile(settingsPath);
  const runs = settings.runs.map((run, index) => normalizeRunSetting(run, index));
  ensureUniqueRunIds(runs);

  const benchmarks = resolveBenchmarks(cli.benchmarks ?? parseBenchmarksEnv(env.BENCHMARKS), settings.benchmarks) as BenchmarkId[];
  if (benchmarks.length === 0) {
    throw new Error('At least one benchmark must be specified via settings or CLI');
  }

  const pairLabels = deriveLabels(settings, env, mode);
  const maxParallel = cli.maxParallel ?? parseInteger(env.MAX_PARALLEL, DEFAULT_MAX_PARALLEL);
  const persistCsv = cli.persistCsv ?? parseBoolean(env.PERSIST_CSV, false);
  const promPort = cli.promPort ?? parseInteger(env.PROM_PORT, DEFAULT_PROM_PORT);
  const seedBase = cli.seedBase ?? parseInteger(env.SEED_BASE, DEFAULT_SEED_BASE);
  const durationOverrideSec = cli.durationSec ?? parseOptionalInteger(env.DURATION_SEC);

  const metricsRoot = path.resolve(cli.runRoot ?? env.METRICS_ROOT ?? DEFAULT_METRICS_ROOT);
  const paths = buildRunnerPaths(metricsRoot, runId);

  let chain: ChainRuntimeConfig | undefined;
  let addressBookPath: string | undefined;
  if (mode === 'live' || mode === 'fork') {
    addressBookPath = path.resolve(cli.addressBook ?? env.ADDRESS_BOOK_JSON ?? DEFAULT_ADDRESS_BOOK);
    const addressBook = await readAddressBook(addressBookPath);
    const forkDeploy = await readForkDeployJson(env.FORK_DEPLOY_JSON);
    chain = await buildChainRuntimeConfig({
      mode,
      env,
      addressBook,
      addressBookPath,
      forkDeploy,
      runs,
      pairLabels
    });
  }

  return {
    runId,
    mode,
    logLevel,
    benchmarks,
    maxParallel,
    persistCsv,
    promPort,
    seedBase,
    durationOverrideSec,
    pairLabels,
    settings: { ...settings, runs },
    runs,
    paths,
    chain,
    mock: mode === 'mock' ? { mode: 'mock' } : undefined,
    addressBookPath
  };
}

function parseCliOptions(argv: readonly string[]): CliOptions {
  const result: Record<string, unknown> = {};
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
      case 'mode':
        result.mode = value;
        break;
      case 'run-id':
        result.runId = value;
        break;
      case 'settings':
        result.settings = value;
        break;
      case 'duration-sec':
        result.durationSec = value ? parseInteger(value, undefined) : undefined;
        break;
      case 'max-parallel':
        result.maxParallel = value ? parseInteger(value, undefined) : undefined;
        break;
      case 'seed-base':
        result.seedBase = value ? parseInteger(value, undefined) : undefined;
        break;
      case 'benchmarks':
        result.benchmarks = value ? value.split(',').map((item) => item.trim()).filter(Boolean) : [];
        break;
      case 'persist-csv':
        result.persistCsv = value ? parseBoolean(value, true) : true;
        break;
      case 'no-persist-csv':
        result.persistCsv = false;
        break;
      case 'prom-port':
        result.promPort = value ? parseInteger(value, undefined) : undefined;
        break;
      case 'log-level':
        result.logLevel = resolveLogLevel(value);
        break;
      case 'run-root':
        result.runRoot = value;
        break;
      case 'address-book':
        result.addressBook = value;
        break;
      default:
        // ignore unknown flags to allow forward compatibility
        break;
    }
    index += 1;
  }
  return result;
}

function resolveMode(raw?: string): ShadowBotMode {
  if (!raw) return 'mock';
  const lowered = raw.toLowerCase();
  if (lowered === 'live' || lowered === 'fork' || lowered === 'mock') {
    return lowered;
  }
  throw new Error(`Unsupported MODE value: ${raw}`);
}

function resolveLogLevel(raw?: string): 'info' | 'debug' {
  if (!raw) return 'info';
  return raw.toLowerCase() === 'debug' ? 'debug' : 'info';
}

function parseBenchmarksEnv(raw?: string): string[] | undefined {
  if (!raw) return undefined;
  return raw
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function resolveBenchmarks(cli: string[] | undefined, fromSettings: readonly string[] | undefined): string[] {
  const source = cli && cli.length > 0 ? cli : fromSettings ?? [];
  const allowed = new Set(['dnmm', 'cpmm', 'stableswap']);
  return source.map((item) => item.toLowerCase()).filter((item) => {
    if (!allowed.has(item)) {
      throw new Error(`Unsupported benchmark requested: ${item}`);
    }
    return true;
  });
}

function parseBoolean(raw: string | boolean | undefined, fallback: boolean): boolean {
  if (typeof raw === 'boolean') return raw;
  if (!raw) return fallback;
  const lowered = raw.toLowerCase();
  if (lowered === 'true' || lowered === '1' || lowered === 'yes') return true;
  if (lowered === 'false' || lowered === '0' || lowered === 'no') return false;
  return fallback;
}

function parseInteger(raw: string | number | undefined, fallback: number | undefined): number {
  if (typeof raw === 'number') {
    if (!Number.isFinite(raw)) throw new Error('Numeric value must be finite');
    return Math.trunc(raw);
  }
  if (raw === undefined) {
    if (fallback === undefined) throw new Error('Missing required integer value');
    return fallback;
  }
  const parsed = Number.parseInt(raw, 10);
  if (Number.isNaN(parsed)) {
    if (fallback === undefined) {
      throw new Error(`Unable to parse integer from value: ${raw}`);
    }
    return fallback;
  }
  return parsed;
}

function parseOptionalInteger(raw: string | undefined): number | undefined {
  if (!raw) return undefined;
  const parsed = Number.parseInt(raw, 10);
  return Number.isNaN(parsed) ? undefined : parsed;
}

function sanitizeRunId(runId: string): string {
  return runId.replace(/[^a-zA-Z0-9_-]/g, '-');
}

function createDefaultRunId(): string {
  const now = new Date();
  return now.toISOString().replace(/[:.]/g, '-');
}

async function loadSettingsFile(settingsPath: string): Promise<SettingsFileSchema> {
  try {
    const contents = await fs.readFile(settingsPath, 'utf8');
    const parsed = JSON.parse(contents) as SettingsFileSchema;
    if (!parsed || typeof parsed !== 'object') {
      throw new Error('Settings file must contain a JSON object');
    }
    if (!Array.isArray(parsed.runs) || parsed.runs.length === 0) {
      throw new Error('Settings file must include a non-empty runs array');
    }
    return parsed;
  } catch (error) {
    throw new Error(`Failed to load settings file at ${settingsPath}: ${(error as Error).message}`);
  }
}

function buildRunnerPaths(metricsRoot: string, runId: string): RunnerPaths {
  const runRoot = path.join(metricsRoot, `run_${runId}`);
  const tradesDir = path.join(runRoot, 'trades');
  const quotesDir = path.join(runRoot, 'quotes');
  const scoreboardPath = path.join(runRoot, 'scoreboard.csv');
  return { runRoot, tradesDir, quotesDir, scoreboardPath };
}

function deriveLabels(settings: SettingsFileSchema, env: NodeJS.ProcessEnv, mode: ShadowBotMode): ShadowBotLabels {
  const pair = settings.pair ?? env.PAIR ?? 'HYPE/USDC';
  const [baseSymbolDefault, quoteSymbolDefault] = pair.includes('/')
    ? pair.split('/')
    : [settings.baseSymbol ?? 'HYPE', settings.quoteSymbol ?? 'USDC'];
  const baseSymbol = settings.baseSymbol ?? env.BASE_SYMBOL ?? baseSymbolDefault;
  const quoteSymbol = settings.quoteSymbol ?? env.QUOTE_SYMBOL ?? quoteSymbolDefault;
  const chainLabel = env.CHAIN_LABEL ?? (mode === 'live' ? 'hyperEVM' : mode === 'fork' ? 'hyperEVM-fork' : 'mock');
  return {
    pair,
    baseSymbol,
    quoteSymbol,
    chain: chainLabel
  };
}

function ensureUniqueRunIds(runs: readonly RunSettingDefinition[]): void {
  const ids = new Set<string>();
  for (const run of runs) {
    if (ids.has(run.id)) {
      throw new Error(`Duplicate run id detected in settings: ${run.id}`);
    }
    ids.add(run.id);
  }
}

function normalizeRunSetting(raw: RunSettingDefinition, index: number): RunSettingDefinition {
  if (!raw || typeof raw !== 'object') {
    throw new Error(`Run definition at index ${index} is not an object`);
  }
  const id = requireString((raw as Record<string, unknown>).id, `runs[${index}].id`);
  const label = requireString((raw as Record<string, unknown>).label, `runs[${index}].label`);
  const featureFlags = normalizeFeatureFlags((raw as Record<string, unknown>).featureFlags, index);
  const makerParams = normalizeMakerParams((raw as Record<string, unknown>).makerParams, index);
  const inventoryParams = normalizeInventoryParams((raw as Record<string, unknown>).inventoryParams, index);
  const aomqParams = normalizeAomqParams((raw as Record<string, unknown>).aomqParams, index);
  const flow = normalizeFlowConfig((raw as Record<string, unknown>).flow, index);
  const latency = normalizeLatency((raw as Record<string, unknown>).latency, index);
  const router = normalizeRouter((raw as Record<string, unknown>).router, index);
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
  const candidate = expectRecord(raw, `runs[${index}].featureFlags`);
  return {
    enableSoftDivergence: parseBoolean(candidate.enableSoftDivergence, true),
    enableSizeFee: parseBoolean(candidate.enableSizeFee, false),
    enableBboFloor: parseBoolean(candidate.enableBboFloor, true),
    enableInvTilt: parseBoolean(candidate.enableInvTilt, true),
    enableAOMQ: parseBoolean(candidate.enableAOMQ, false),
    enableRebates: parseBoolean(candidate.enableRebates, false)
  };
}

function normalizeMakerParams(raw: unknown, index: number): RunMakerParams {
  const candidate = expectRecord(raw, `runs[${index}].makerParams`);
  return {
    betaFloorBps: toNumber(candidate.betaFloorBps, `runs[${index}].makerParams.betaFloorBps`),
    alphaBboBps: toNumber(candidate.alphaBboBps, `runs[${index}].makerParams.alphaBboBps`),
    s0Notional: toNumber(candidate.S0Notional ?? candidate.s0Notional, `runs[${index}].makerParams.S0Notional`)
  };
}

function normalizeInventoryParams(raw: unknown, index: number): RunInventoryParams {
  const candidate = expectRecord(raw, `runs[${index}].inventoryParams`);
  return {
    invTiltBpsPer1pct: toNumber(candidate.invTiltBpsPer1pct, `runs[${index}].inventoryParams.invTiltBpsPer1pct`),
    invTiltMaxBps: toNumber(candidate.invTiltMaxBps, `runs[${index}].inventoryParams.invTiltMaxBps`),
    tiltConfWeightBps: toNumber(candidate.tiltConfWeightBps, `runs[${index}].inventoryParams.tiltConfWeightBps`),
    tiltSpreadWeightBps: toNumber(candidate.tiltSpreadWeightBps, `runs[${index}].inventoryParams.tiltSpreadWeightBps`)
  };
}

function normalizeAomqParams(raw: unknown, index: number): RunAomqParams {
  const candidate = expectRecord(raw, `runs[${index}].aomqParams`);
  return {
    minQuoteNotional: toNumber(candidate.minQuoteNotional, `runs[${index}].aomqParams.minQuoteNotional`),
    emergencySpreadBps: toNumber(candidate.emergencySpreadBps, `runs[${index}].aomqParams.emergencySpreadBps`),
    floorEpsilonBps: toNumber(candidate.floorEpsilonBps, `runs[${index}].aomqParams.floorEpsilonBps`)
  };
}

function normalizeFlowConfig(raw: unknown, index: number): FlowPatternConfig {
  const candidate = expectRecord(raw, `runs[${index}].flow`);
  const patternRaw = requireString(candidate.pattern, `runs[${index}].flow.pattern`).toLowerCase();
  const allowedPatterns: FlowPatternConfig['pattern'][] = [
    'arb_constant',
    'toxic',
    'trend',
    'mean_revert',
    'benign_poisson',
    'mixed'
  ];
  if (!(allowedPatterns as readonly string[]).includes(patternRaw)) {
    throw new Error(`Unsupported flow pattern: ${patternRaw}`);
  }
  const pattern = patternRaw as FlowPatternConfig['pattern'];
  const seconds = toNumber(candidate.seconds, `runs[${index}].flow.seconds`);
  const seed = toNumber(candidate.seed, `runs[${index}].flow.seed`);
  const txnRatePerMin = toNumber(candidate.txn_rate_per_min ?? candidate.txnRatePerMin, `runs[${index}].flow.txn_rate_per_min`);
  const sizeDistRaw = (candidate.size_dist ?? candidate.sizeDist ?? 'lognormal') as FlowSizeDistributionKind;
  const sizeParams = normalizeFlowSizeDistribution(sizeDistRaw, candidate.size_params ?? candidate.sizeParams, index);
  const toxicity = candidate.toxicity ? normalizeFlowToxicity(candidate.toxicity, index) : undefined;
  return {
    pattern,
    seconds,
    seed,
    txnRatePerMin,
    size: sizeParams,
    toxicity
  };
}

function normalizeFlowSizeDistribution(
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
      sigma: toNumber(params.sigma ?? params.alpha ?? 1, `runs[${index}].flow.size_params.sigma`),
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
  throw new Error(`Unsupported flow size distribution kind: ${kind}`);
}

function normalizeFlowToxicity(raw: unknown, index: number): FlowToxicityConfig {
  const candidate = expectRecord(raw, `runs[${index}].flow.toxicity`);
  return {
    oracleLeadMs: toNumber(candidate.oracle_lead_ms ?? candidate.oracleLeadMs, `runs[${index}].flow.toxicity.oracle_lead_ms`),
    edgeBpsMu: toNumber(candidate.edge_bps_mu ?? candidate.edgeBpsMu, `runs[${index}].flow.toxicity.edge_bps_mu`),
    edgeBpsSigma: toNumber(candidate.edge_bps_sigma ?? candidate.edgeBpsSigma, `runs[${index}].flow.toxicity.edge_bps_sigma`)
  };
}

function normalizeLatency(raw: unknown, index: number): LatencyProfile {
  const candidate = expectRecord(raw, `runs[${index}].latency`);
  return {
    quoteToTxMs: toNumber(candidate.quote_to_tx_ms ?? candidate.quoteToTxMs, `runs[${index}].latency.quote_to_tx_ms`),
    jitterMs: toNumber(candidate.jitter_ms ?? candidate.jitterMs, `runs[${index}].latency.jitter_ms`)
  };
}

function normalizeRouter(raw: unknown, index: number): RouterConfig {
  const candidate = expectRecord(raw, `runs[${index}].router`);
  const policyRaw = requireString(candidate.minOut_policy ?? candidate.minOutPolicy, `runs[${index}].router.minOut_policy`).toLowerCase();
  const allowedPolicies: RouterConfig['minOutPolicy'][] = ['preview', 'preview_ladder', 'fixed_margin'];
  if (!allowedPolicies.includes(policyRaw as RouterConfig['minOutPolicy'])) {
    throw new Error(`Unsupported router minOut policy: ${policyRaw}`);
  }
  return {
    slippageBps: toNumber(candidate.slippage_bps ?? candidate.slippageBps, `runs[${index}].router.slippage_bps`),
    ttlSec: toNumber(candidate.ttl_sec ?? candidate.ttlSec, `runs[${index}].router.ttl_sec`),
    minOutPolicy: policyRaw as RouterConfig['minOutPolicy']
  };
}

function expectRecord(value: unknown, label: string): Record<string, any> {
  if (!value || typeof value !== 'object') {
    throw new Error(`${label} must be an object`);
  }
  return value as Record<string, any>;
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

async function readAddressBook(addressBookPath: string): Promise<AddressBookFile | undefined> {
  try {
    const data = await fs.readFile(addressBookPath, 'utf8');
    const parsed = JSON.parse(data) as AddressBookFile;
    if (!parsed || typeof parsed !== 'object' || !parsed.deployments) {
      throw new Error('Invalid address-book schema');
    }
    return parsed;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return undefined;
    }
    throw error;
  }
}

interface ForkDeployJson {
  readonly chainId?: number;
  readonly poolAddress?: string;
  readonly hypeAddress?: string;
  readonly usdcAddress?: string;
  readonly pythAddress?: string;
  readonly baseDecimals?: number;
  readonly quoteDecimals?: number;
  readonly hcPxPrecompile?: string;
  readonly hcBboPrecompile?: string;
  readonly hcPxKey?: number;
  readonly hcBboKey?: number;
  readonly wsUrl?: string;
}

async function readForkDeployJson(pathOrUndefined: string | undefined): Promise<ForkDeployJson | undefined> {
  if (!pathOrUndefined) return undefined;
  try {
    const contents = await fs.readFile(pathOrUndefined, 'utf8');
    return JSON.parse(contents) as ForkDeployJson;
  } catch (error) {
    throw new Error(`Failed to parse fork deploy JSON: ${(error as Error).message}`);
  }
}

interface ChainBuildParams {
  readonly mode: 'live' | 'fork';
  readonly env: NodeJS.ProcessEnv;
  readonly addressBook?: AddressBookFile;
  readonly addressBookPath: string;
  readonly forkDeploy?: ForkDeployJson;
  readonly runs: readonly RunSettingDefinition[];
  readonly pairLabels: ShadowBotLabels;
}

async function buildChainRuntimeConfig(params: ChainBuildParams): Promise<ChainRuntimeConfig> {
  const { mode, env, addressBook, addressBookPath, forkDeploy } = params;
  const rpcUrl = requireEnv(env, 'RPC_URL');
  const wsUrl = env.WS_URL ?? forkDeploy?.wsUrl;
  const chainId = parseOptionalInteger(env.CHAIN_ID) ?? forkDeploy?.chainId ?? addressBook?.defaultChainId;

  const poolAddress = ensureHex(env.POOL_ADDR ?? env.DNMM_POOL_ADDRESS ?? forkDeploy?.poolAddress, 'POOL_ADDR');
  const entry = resolveAddressBookEntry(addressBook, chainId, poolAddress);

  const hcPxPrecompile = ensureHex(
    env.HC_PX_PRECOMPILE ?? forkDeploy?.hcPxPrecompile ?? entry?.hcPx ?? '0x0000000000000000000000000000000000000807',
    'HC_PX_PRECOMPILE'
  );
  const hcBboPrecompile = ensureHex(
    env.HC_BBO_PRECOMPILE ?? forkDeploy?.hcBboPrecompile ?? entry?.hcBbo ?? '0x000000000000000000000000000000000000080e',
    'HC_BBO_PRECOMPILE'
  );
  const hcPxKey = parseInteger(env.HC_PX_KEY ?? forkDeploy?.hcPxKey ?? '107', 107);
  const hcBboKey = parseInteger(env.HC_BBO_KEY ?? forkDeploy?.hcBboKey ?? hcPxKey, hcPxKey);
  const hcMarketType = (env.HC_MARKET_TYPE ?? 'spot').toLowerCase() === 'perp' ? 'perp' : 'spot';
  const hcSizeDecimals = parseInteger(env.HC_SIZE_DECIMALS ?? entry?.hcSizeDecimals, entry?.hcSizeDecimals ?? 2);
  const hcPxMultiplier = hcMarketType === 'spot'
    ? 10n ** BigInt(10 + hcSizeDecimals)
    : 10n ** BigInt(12 + hcSizeDecimals);

  const baseTokenAddress = ensureHex(env.HYPE_ADDR ?? forkDeploy?.hypeAddress ?? entry?.baseToken, 'HYPE_ADDR');
  const quoteTokenAddress = ensureHex(env.USDC_ADDR ?? forkDeploy?.usdcAddress ?? entry?.quoteToken, 'USDC_ADDR');
  const baseDecimals = parseInteger(env.BASE_DECIMALS ?? forkDeploy?.baseDecimals ?? entry?.baseDecimals, entry?.baseDecimals ?? 18);
  const quoteDecimals = parseInteger(env.QUOTE_DECIMALS ?? forkDeploy?.quoteDecimals ?? entry?.quoteDecimals, entry?.quoteDecimals ?? 6);
  const pythAddress = env.PYTH_ADDR ?? forkDeploy?.pythAddress ?? entry?.pyth;
  const pythPriceId = env.PYTH_PRICE_ID ?? env.PYTH_PAIR_FEED_ID ?? entry?.pythPriceId;
  const gasPriceGwei = env.GAS_PRICE_GWEI ? Number(env.GAS_PRICE_GWEI) : undefined;
  const nativeUsd = env.NATIVE_USD ? Number(env.NATIVE_USD) : undefined;

  return {
    mode,
    rpcUrl,
    wsUrl,
    chainId,
    poolAddress,
    baseTokenAddress,
    quoteTokenAddress,
    baseDecimals,
    quoteDecimals,
    pythAddress,
    hcPxPrecompile,
    hcBboPrecompile,
    hcPxKey,
    hcBboKey,
    hcMarketType,
    hcSizeDecimals,
    hcPxMultiplier,
    pythPriceId,
    gasPriceGwei,
    nativeUsd,
    addressBookSource: addressBook ? addressBookPath : undefined
  };
}

function requireEnv(env: NodeJS.ProcessEnv, key: string): string {
  const value = env[key];
  if (!value || value.trim().length === 0) {
    throw new Error(`Missing required environment variable ${key}`);
  }
  return value.trim();
}

function ensureHex(value: string | undefined, label: string): string {
  if (!value) {
    throw new Error(`Missing required value for ${label}`);
  }
  if (!value.startsWith('0x')) {
    throw new Error(`${label} must be a 0x-prefixed hex string`);
  }
  return value;
}

function resolveAddressBookEntry(
  addressBook: AddressBookFile | undefined,
  chainId: number | undefined,
  poolAddress: string
): AddressBookEntry | undefined {
  if (!addressBook) return undefined;
  const deployments = Object.values(addressBook.deployments ?? {});
  return deployments.find((deployment) => {
    const matchesChain = chainId ? deployment.chainId === chainId : true;
    const matchesPool = deployment.poolAddress?.toLowerCase() === poolAddress.toLowerCase();
    return matchesChain && matchesPool;
  });
}
