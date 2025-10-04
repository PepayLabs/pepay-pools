import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';
import { parseUnits } from 'ethers';
import { z } from 'zod';
import {
  AddressBookEntry,
  AddressBookFile,
  ChainBackedConfig,
  HistogramBuckets,
  MockShadowBotConfig,
  ShadowBotConfig,
  ShadowBotLabels,
  ShadowBotMode,
  ShadowBotParameters
} from './types.js';
import parametersDefaultsJson from '../config/parameters_default.json' assert { type: 'json' };

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_PAIR = 'HYPE/USDC';
const DEFAULT_BASE_SYMBOL = 'HYPE';
const DEFAULT_QUOTE_SYMBOL = 'USDC';
const DEFAULT_INTERVAL_MS = 5_000;
const DEFAULT_TIMEOUT_MS = 7_500;
const DEFAULT_BACKOFF_MS = 500;
const DEFAULT_RETRIES = 3;
const DEFAULT_SNAPSHOT_MAX_AGE_SEC = 30;
const DEFAULT_PROM_PORT = 9_464;
const DEFAULT_CSV_DIR = path.resolve(__dirname, '../metrics/hype-metrics');
const DEFAULT_SUMMARY_PATH = path.join(DEFAULT_CSV_DIR, 'shadow_summary.json');
const DEFAULT_ADDRESS_BOOK = path.resolve(__dirname, 'address-book.json');
const DEFAULT_HISTOGRAM_BUCKETS: HistogramBuckets = {
  deltaBps: [5, 10, 20, 30, 40, 50, 75, 100, 200, 500],
  confBps: [10, 20, 40, 60, 80, 100, 150, 200],
  bboSpreadBps: [5, 10, 20, 30, 40, 50, 75, 100, 200],
  quoteLatencyMs: [5, 10, 20, 50, 100, 200, 500, 1_000],
  feeBps: [5, 10, 15, 20, 30, 40, 60, 80, 100, 150],
  totalBps: [5, 10, 15, 20, 30, 40, 60, 80, 100, 150, 200]
};
const DEFAULT_MODE: ShadowBotMode = 'mock';
const DEFAULT_SCENARIO = 'calm';
const DEFAULT_FORK_OUTPUT_PATH = path.resolve(
  __dirname,
  '../metrics/hype-metrics/output/deploy-mocks.json'
);

const PARAMETERS_SCHEMA = z
  .object({
    enableLvrFee: z.boolean().default(false),
    oracle: z.object({
      hypercore: z.object({
        confCapBpsSpot: z.number(),
        confCapBpsStrict: z.number(),
        maxAgeSec: z.number(),
        stallWindowSec: z.number(),
        allowEmaFallback: z.boolean(),
        divergenceBps: z.number(),
        divergenceAcceptBps: z.number(),
        divergenceSoftBps: z.number(),
        divergenceHardBps: z.number(),
        haircutMinBps: z.number(),
        haircutSlopeBps: z.number(),
        confWeightSpreadBps: z.number(),
        confWeightSigmaBps: z.number(),
        confWeightPythBps: z.number(),
        sigmaEwmaLambdaBps: z.number()
      }),
      pyth: z.object({
        maxAgeSec: z.number(),
        maxAgeSecStrict: z.number(),
        confCapBps: z.number()
      })
    }),
    fee: z.object({
      baseBps: z.number(),
      alphaConfNumerator: z.number(),
      alphaConfDenominator: z.number(),
      betaInvDevNumerator: z.number(),
      betaInvDevDenominator: z.number(),
      capBps: z.number(),
      decayPctPerBlock: z.number(),
      gammaSizeLinBps: z.number(),
      gammaSizeQuadBps: z.number(),
      sizeFeeCapBps: z.number(),
      kappaLvrBps: z.number()
    }),
    inventory: z.object({
      floorBps: z.number(),
      recenterThresholdPct: z.number(),
      initialTargetBaseXstar: z.union([z.literal('auto'), z.string()]),
      invTiltBpsPer1pct: z.number(),
      invTiltMaxBps: z.number(),
      tiltConfWeightBps: z.number(),
      tiltSpreadWeightBps: z.number()
    }),
    maker: z.object({
      S0Notional: z.number(),
      ttlMs: z.number(),
      alphaBboBps: z.number(),
      betaFloorBps: z.number()
    }),
    preview: z.object({
      maxAgeSec: z.number(),
      snapshotCooldownSec: z.number(),
      revertOnStalePreview: z.boolean(),
      enablePreviewFresh: z.boolean()
    }),
    featureFlags: z.object({
      blendOn: z.boolean(),
      parityCiOn: z.boolean(),
      debugEmit: z.boolean(),
      enableSoftDivergence: z.boolean(),
      enableSizeFee: z.boolean(),
      enableBboFloor: z.boolean(),
      enableInvTilt: z.boolean(),
      enableAOMQ: z.boolean(),
      enableRebates: z.boolean(),
      enableAutoRecenter: z.boolean(),
      enableLvrFee: z.boolean()
    }),
    aomq: z.object({
      minQuoteNotional: z.number(),
      emergencySpreadBps: z.number(),
      floorEpsilonBps: z.number()
    }),
    rebates: z.object({
      allowlist: z.array(z.string())
    })
  })
  .passthrough();

type ParametersSchema = z.infer<typeof PARAMETERS_SCHEMA>;

const PARAMETERS_DEFAULTS = PARAMETERS_SCHEMA.parse(parametersDefaultsJson);

function must(envName: string): string {
  const value = process.env[envName];
  if (!value || value.trim().length === 0) {
    throw new Error(`Missing required environment variable ${envName}`);
  }
  return value.trim();
}

function getOptional(envName: string): string | undefined {
  const value = process.env[envName];
  if (!value || value.trim().length === 0) {
    return undefined;
  }
  return value.trim();
}

async function readAddressBook(addressBookPath: string): Promise<AddressBookFile | undefined> {
  try {
    const data = await fs.readFile(addressBookPath, 'utf8');
    const parsed = JSON.parse(data) as AddressBookFile;
    if (!parsed || typeof parsed !== 'object' || !parsed.deployments) {
      throw new Error('Invalid address-book.json schema');
    }
    return parsed;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return undefined;
    }
    throw error;
  }
}

function ensureHex(address: string | undefined, label: string): string {
  if (!address) {
    throw new Error(`Missing required address for ${label}`);
  }
  if (!address.startsWith('0x')) {
    throw new Error(`Address ${label} must be 0x-prefixed`);
  }
  return address;
}

function parseIntEnv(envName: string, fallback: number): number {
  const value = getOptional(envName);
  if (!value) return fallback;
  const parsed = Number.parseInt(value, 10);
  if (Number.isNaN(parsed)) {
    throw new Error(`Environment variable ${envName} must be an integer`);
  }
  return parsed;
}

function parseFloatEnv(envName: string): number | undefined {
  const value = getOptional(envName);
  if (!value) return undefined;
  const parsed = Number.parseFloat(value);
  if (Number.isNaN(parsed)) {
    throw new Error(`Environment variable ${envName} must be numeric`);
  }
  return parsed;
}

function parseBoolEnv(envName: string, fallback: boolean): boolean {
  const value = getOptional(envName);
  if (!value) return fallback;
  const normalized = value.trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  throw new Error(`Environment variable ${envName} must be boolean`);
}

function parseListEnv(envName: string, fallback: readonly string[]): string[] {
  const value = getOptional(envName);
  if (!value) return [...fallback];
  return value
    .split(/[,;\n]+/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function buildParameters(): ShadowBotParameters {
  const defaults: ParametersSchema = PARAMETERS_DEFAULTS;
  return {
    enableLvrFee: parseBoolEnv('ENABLE_LVR_FEE', defaults.enableLvrFee ?? false),
    oracle: {
      hypercore: { ...defaults.oracle.hypercore },
      pyth: {
        maxAgeSec: parseIntEnv('PYTH_MAX_AGE_SEC', defaults.oracle.pyth.maxAgeSec),
        maxAgeSecStrict: parseIntEnv(
          'PYTH_MAX_AGE_SEC_STRICT',
          defaults.oracle.pyth.maxAgeSecStrict
        ),
        confCapBps: parseIntEnv('PYTH_CONF_CAP_BPS', defaults.oracle.pyth.confCapBps)
      }
    },
    fee: {
      baseBps: defaults.fee.baseBps,
      alphaConfNumerator: defaults.fee.alphaConfNumerator,
      alphaConfDenominator: defaults.fee.alphaConfDenominator,
      betaInvDevNumerator: defaults.fee.betaInvDevNumerator,
      betaInvDevDenominator: defaults.fee.betaInvDevDenominator,
      capBps: defaults.fee.capBps,
      decayPctPerBlock: defaults.fee.decayPctPerBlock,
      gammaSizeLinBps: defaults.fee.gammaSizeLinBps,
      gammaSizeQuadBps: defaults.fee.gammaSizeQuadBps,
      sizeFeeCapBps: defaults.fee.sizeFeeCapBps,
      kappaLvrBps: parseIntEnv('FEE_KAPPA_LVR_BPS', defaults.fee.kappaLvrBps)
    },
    inventory: {
      floorBps: defaults.inventory.floorBps,
      recenterThresholdPct: defaults.inventory.recenterThresholdPct,
      initialTargetBaseXstar: defaults.inventory.initialTargetBaseXstar,
      invTiltBpsPer1pct: defaults.inventory.invTiltBpsPer1pct,
      invTiltMaxBps: defaults.inventory.invTiltMaxBps,
      tiltConfWeightBps: defaults.inventory.tiltConfWeightBps,
      tiltSpreadWeightBps: defaults.inventory.tiltSpreadWeightBps
    },
    maker: {
      S0Notional: defaults.maker.S0Notional,
      ttlMs: parseIntEnv('MAKER_TTL_MS', defaults.maker.ttlMs),
      alphaBboBps: defaults.maker.alphaBboBps,
      betaFloorBps: defaults.maker.betaFloorBps
    },
    preview: {
      maxAgeSec: parseIntEnv('PREVIEW_MAX_AGE_SEC', defaults.preview.maxAgeSec),
      snapshotCooldownSec: defaults.preview.snapshotCooldownSec,
      revertOnStalePreview: parseBoolEnv(
        'PREVIEW_REVERT_ON_STALE',
        defaults.preview.revertOnStalePreview
      ),
      enablePreviewFresh: defaults.preview.enablePreviewFresh
    },
    featureFlags: {
      blendOn: defaults.featureFlags.blendOn,
      parityCiOn: defaults.featureFlags.parityCiOn,
      debugEmit: defaults.featureFlags.debugEmit,
      enableSoftDivergence: defaults.featureFlags.enableSoftDivergence,
      enableSizeFee: defaults.featureFlags.enableSizeFee,
      enableBboFloor: defaults.featureFlags.enableBboFloor,
      enableInvTilt: defaults.featureFlags.enableInvTilt,
      enableAOMQ: parseBoolEnv('FEATURE_ENABLE_AOMQ', defaults.featureFlags.enableAOMQ),
      enableRebates: parseBoolEnv('FEATURE_ENABLE_REBATES', defaults.featureFlags.enableRebates),
      enableAutoRecenter: defaults.featureFlags.enableAutoRecenter,
      enableLvrFee: parseBoolEnv('FEATURE_ENABLE_LVR_FEE', defaults.featureFlags.enableLvrFee)
    },
    aomq: {
      minQuoteNotional: parseIntEnv('AOMQ_MIN_QUOTE_NOTIONAL', defaults.aomq.minQuoteNotional),
      emergencySpreadBps: parseIntEnv(
        'AOMQ_EMERGENCY_SPREAD_BPS',
        defaults.aomq.emergencySpreadBps
      ),
      floorEpsilonBps: parseIntEnv('AOMQ_FLOOR_EPSILON_BPS', defaults.aomq.floorEpsilonBps)
    },
    rebates: {
      allowlist: parseListEnv('REBATES_ALLOWLIST', defaults.rebates.allowlist)
    }
  };
}
function parseLogLevel(): 'info' | 'debug' {
  const level = getOptional('LOG_LEVEL');
  if (!level) return 'info';
  return level === 'debug' ? 'debug' : 'info';
}

function normalizeSizeToken(value: string): bigint {
  const trimmed = value.trim();
  if (/^0x[0-9a-fA-F]+$/.test(trimmed)) {
    return BigInt(trimmed);
  }
  if (/^[0-9]+$/.test(trimmed)) {
    return BigInt(trimmed);
  }
  if (/^[0-9]+(\.[0-9]+)?$/.test(trimmed)) {
    return parseUnits(trimmed, 18);
  }
  const scientific = trimmed.match(/^([0-9]+(?:\.[0-9]+)?)e([+-]?[0-9]+)$/i);
  if (scientific) {
    const [, coeffStr, expStr] = scientific;
    const exp = Number.parseInt(expStr, 10);
    const [intPart, fracPart = ''] = coeffStr.split('.');
    const digits = `${intPart}${fracPart}`;
    const decimalPlaces = fracPart.length;
    return BigInt(digits) * 10n ** BigInt(exp - decimalPlaces);
  }
  throw new Error(`Unable to parse size value '${value}' as WAD`);
}

function deriveSizeGrid(): { grid: bigint[]; source: string } {
  const raw = getOptional('SIZES_WAD');
  if (!raw) {
    const defaults = ['0.1', '0.5', '1', '2', '5', '10'];
    return { grid: defaults.map((entry) => parseUnits(entry, 18)), source: 'default' };
  }
  const values = raw.split(',').map((token) => token.trim()).filter(Boolean);
  if (values.length === 0) {
    throw new Error('SIZES_WAD provided but empty after parsing');
  }
  const grid = values.map(normalizeSizeToken);
  return { grid, source: 'env' };
}

function resolveLabels(baseSymbol: string, quoteSymbol: string, pairLabel: string): ShadowBotLabels {
  return {
    baseSymbol,
    quoteSymbol,
    pair: pairLabel,
    chain: 'HypeEVM'
  };
}

function deriveHistogramBuckets(): HistogramBuckets {
  const override = getOptional('HISTOGRAM_BUCKETS_JSON');
  if (!override) return DEFAULT_HISTOGRAM_BUCKETS;
  try {
    const parsed = JSON.parse(override) as Partial<HistogramBuckets>;
    return {
      deltaBps: parsed.deltaBps ?? DEFAULT_HISTOGRAM_BUCKETS.deltaBps,
      confBps: parsed.confBps ?? DEFAULT_HISTOGRAM_BUCKETS.confBps,
      bboSpreadBps: parsed.bboSpreadBps ?? DEFAULT_HISTOGRAM_BUCKETS.bboSpreadBps,
      quoteLatencyMs: parsed.quoteLatencyMs ?? DEFAULT_HISTOGRAM_BUCKETS.quoteLatencyMs,
      feeBps: parsed.feeBps ?? DEFAULT_HISTOGRAM_BUCKETS.feeBps,
      totalBps: parsed.totalBps ?? DEFAULT_HISTOGRAM_BUCKETS.totalBps
    };
  } catch (error) {
    throw new Error(`Failed to parse HISTOGRAM_BUCKETS_JSON: ${(error as Error).message}`);
  }
}

function parseMode(): ShadowBotMode {
  const raw = (process.env.MODE ?? DEFAULT_MODE).toLowerCase();
  if (raw === 'live' || raw === 'fork' || raw === 'mock') {
    return raw;
  }
  throw new Error(`Unsupported MODE '${raw}'. Expected one of live | fork | mock.`);
}

interface ForkDeployJson {
  readonly chainId?: number;
  readonly poolAddress?: string;
  readonly hypeAddress?: string;
  readonly usdcAddress?: string;
  readonly pythAddress?: string;
  readonly hcPxPrecompile?: string;
  readonly hcBboPrecompile?: string;
  readonly hcPxKey?: number;
  readonly hcBboKey?: number;
  readonly baseDecimals?: number;
  readonly quoteDecimals?: number;
  readonly wsUrl?: string;
}

function toMaybeString(value: unknown): string | undefined {
  if (typeof value === 'string' && value.trim().length > 0) {
    return value.trim();
  }
  return undefined;
}

function toMaybeNumber(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === 'string' && value.trim().length > 0) {
    const parsed = Number.parseInt(value.trim(), 10);
    if (!Number.isNaN(parsed)) {
      return parsed;
    }
  }
  return undefined;
}

function normalizeForkDeploy(raw: unknown): ForkDeployJson {
  if (!raw || typeof raw !== 'object') {
    throw new Error('fork deploy JSON is malformed');
  }
  const candidate = raw as Record<string, unknown>;
  return {
    chainId: toMaybeNumber(candidate.chainId ?? candidate.chain_id),
    poolAddress: toMaybeString(candidate.poolAddress ?? candidate.pool ?? candidate.pool_addr),
    hypeAddress: toMaybeString(candidate.hypeAddress ?? candidate.hype ?? candidate.hype_addr),
    usdcAddress: toMaybeString(candidate.usdcAddress ?? candidate.usdc ?? candidate.usdc_addr),
    pythAddress: toMaybeString(candidate.pythAddress ?? candidate.pyth ?? candidate.pyth_addr),
    hcPxPrecompile: toMaybeString(candidate.hcPxPrecompile ?? candidate.hcPx ?? candidate.hc_px_precompile),
    hcBboPrecompile: toMaybeString(candidate.hcBboPrecompile ?? candidate.hcBbo ?? candidate.hc_bbo_precompile),
    hcPxKey: toMaybeNumber(candidate.hcPxKey ?? candidate.hc_px_key),
    hcBboKey: toMaybeNumber(candidate.hcBboKey ?? candidate.hc_bbo_key),
    baseDecimals: toMaybeNumber(candidate.baseDecimals ?? candidate.base_decimals),
    quoteDecimals: toMaybeNumber(candidate.quoteDecimals ?? candidate.quote_decimals),
    wsUrl: toMaybeString(candidate.wsUrl ?? candidate.ws_url)
  };
}

async function readForkDeployJson(filePath?: string): Promise<ForkDeployJson | undefined> {
  const resolved = filePath ?? DEFAULT_FORK_OUTPUT_PATH;
  try {
    const content = await fs.readFile(resolved, 'utf8');
    return normalizeForkDeploy(JSON.parse(content));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return undefined;
    }
    throw error;
  }
}

function resolveAddressBookEntry(
  addressBook: AddressBookFile | undefined,
  chainId: number | undefined,
  poolAddress: string | undefined
): AddressBookEntry | undefined {
  if (!addressBook) return undefined;
  if (poolAddress) {
    const key = Object.keys(addressBook.deployments).find(
      (deploymentKey) => addressBook.deployments[deploymentKey].poolAddress?.toLowerCase() === poolAddress.toLowerCase()
    );
    if (key) return addressBook.deployments[key];
  }
  if (chainId !== undefined) {
    const match = Object.values(addressBook.deployments).find((entry) => entry.chainId === chainId);
    if (match) return match;
  }
  if (addressBook.defaultChainId !== undefined) {
    const match = Object.values(addressBook.deployments).find((entry) => entry.chainId === addressBook.defaultChainId);
    if (match) return match;
  }
  return undefined;
}

export async function loadConfig(): Promise<ShadowBotConfig> {
  const mode = parseMode();

  const baseSymbol = getOptional('BASE_SYMBOL') ?? DEFAULT_BASE_SYMBOL;
  const quoteSymbol = getOptional('QUOTE_SYMBOL') ?? DEFAULT_QUOTE_SYMBOL;
  const pairLabel = getOptional('PAIR_LABEL') ?? DEFAULT_PAIR;
  const labels = resolveLabels(baseSymbol, quoteSymbol, pairLabel);

  const { grid: sizeGrid, source: sizesSource } = deriveSizeGrid();
  const intervalMs = parseIntEnv('INTERVAL_MS', DEFAULT_INTERVAL_MS);
  const snapshotMaxAgeSec = parseIntEnv('SNAPSHOT_MAX_AGE_SEC', DEFAULT_SNAPSHOT_MAX_AGE_SEC);
  const histogramBuckets = deriveHistogramBuckets();
  const promPort = parseIntEnv('PROM_PORT', DEFAULT_PROM_PORT);
  const logLevel = parseLogLevel();
  const csvDirectory = getOptional('CSV_DIR') ?? DEFAULT_CSV_DIR;
  const jsonSummaryPath = getOptional('JSON_SUMMARY_PATH') ?? DEFAULT_SUMMARY_PATH;
  const samplingTimeout = parseIntEnv('SAMPLING_TIMEOUT_MS', DEFAULT_TIMEOUT_MS);
  const samplingBackoff = parseIntEnv('SAMPLING_BACKOFF_MS', DEFAULT_BACKOFF_MS);
  const samplingAttempts = parseIntEnv('SAMPLING_RETRY_ATTEMPTS', DEFAULT_RETRIES);
  const parameters = buildParameters();
  const guaranteedMinOut = {
    calmBps: parseIntEnv('MIN_OUT_CALM_BPS', 10),
    fallbackBps: parseIntEnv('MIN_OUT_FALLBACK_BPS', 20),
    clampMin: parseIntEnv('MIN_OUT_CLAMP_MIN', 5),
    clampMax: parseIntEnv('MIN_OUT_CLAMP_MAX', 25)
  } as const;
  const sampling = {
    intervalLabel: `${intervalMs}ms`,
    timeoutMs: samplingTimeout,
    retryBackoffMs: samplingBackoff,
    retryAttempts: samplingAttempts
  } as const;
  const gasPriceGwei = parseFloatEnv('GAS_PRICE_GWEI');
  const nativeUsd = parseFloatEnv('NATIVE_USD');
  const pythPriceId = getOptional('PYTH_PRICE_ID') ?? getOptional('PYTH_PAIR_FEED_ID');

  const baseCommon = {
    labels,
    sizeGrid,
    intervalMs,
    snapshotMaxAgeSec,
    histogramBuckets,
    promPort,
    logLevel,
    csvDirectory,
    jsonSummaryPath,
    sizesSource,
    guaranteedMinOut,
    sampling,
    parameters
  } as const;

  if (mode === 'mock') {
    const baseDecimals = parseIntEnv('BASE_DECIMALS', 18);
    const quoteDecimals = parseIntEnv('QUOTE_DECIMALS', 6);
    const scenarioName = (getOptional('SCENARIO') ?? DEFAULT_SCENARIO).toLowerCase();
    const scenarioFile = getOptional('SCENARIO_FILE');

    const mockConfig: MockShadowBotConfig = {
      ...baseCommon,
      mode: 'mock',
      baseDecimals,
      quoteDecimals,
      scenarioName,
      scenarioFile: scenarioFile ?? undefined
    };

    return mockConfig;
  }

  const addressBookPath = getOptional('ADDRESS_BOOK_JSON') ?? DEFAULT_ADDRESS_BOOK;
  const addressBook = await readAddressBook(addressBookPath);
  const forkOverrides = mode === 'fork' ? await readForkDeployJson(getOptional('FORK_DEPLOY_JSON')) : undefined;

  const explicitChainId = getOptional('CHAIN_ID');
  const resolvedChainId = explicitChainId
    ? Number.parseInt(explicitChainId, 10)
    : forkOverrides?.chainId ?? addressBook?.defaultChainId;
  if (explicitChainId && Number.isNaN(resolvedChainId)) {
    throw new Error('CHAIN_ID must be numeric');
  }

  const envPoolAddress = getOptional('POOL_ADDR') ?? getOptional('DNMM_POOL_ADDRESS');
  const detectedEntry = resolveAddressBookEntry(
    addressBook,
    resolvedChainId ?? undefined,
    envPoolAddress ?? forkOverrides?.poolAddress
  );

  const rpcUrl = must('RPC_URL');
  const wsUrl = getOptional('WS_URL') ?? forkOverrides?.wsUrl ?? detectedEntry?.wsUrl;

  const poolAddress = ensureHex(
    envPoolAddress ?? forkOverrides?.poolAddress ?? detectedEntry?.poolAddress,
    'POOL_ADDR'
  );
  const pythAddress = getOptional('PYTH_ADDR') ?? forkOverrides?.pythAddress ?? detectedEntry?.pyth;
  const hcPxPrecompile = ensureHex(
    getOptional('HC_PX_PRECOMPILE') ?? forkOverrides?.hcPxPrecompile ?? detectedEntry?.hcPx ??
      '0x0000000000000000000000000000000000000807',
    'HC_PX_PRECOMPILE'
  );
  const hcBboPrecompile = ensureHex(
    getOptional('HC_BBO_PRECOMPILE') ?? forkOverrides?.hcBboPrecompile ?? detectedEntry?.hcBbo ??
      '0x000000000000000000000000000000000000080e',
    'HC_BBO_PRECOMPILE'
  );
  const hcPxKeyDefault = forkOverrides?.hcPxKey ?? 107;
  const hcPxKey = parseIntEnv('HC_PX_KEY', hcPxKeyDefault);
  const hcBboKey = parseIntEnv('HC_BBO_KEY', forkOverrides?.hcBboKey ?? hcPxKey);
  const hcMarketType = (getOptional('HC_MARKET_TYPE') ?? 'spot').toLowerCase() === 'perp' ? 'perp' : 'spot';
  const hcSizeDecimals = parseIntEnv('HC_SIZE_DECIMALS', 2);
  const hcPxMultiplier = hcMarketType === 'spot'
    ? 10n ** BigInt(10 + hcSizeDecimals)
    : 10n ** BigInt(12 + hcSizeDecimals);

  const baseTokenAddress = ensureHex(
    getOptional('HYPE_ADDR') ?? forkOverrides?.hypeAddress ?? detectedEntry?.baseToken,
    'HYPE_ADDR'
  );
  const quoteTokenAddress = ensureHex(
    getOptional('USDC_ADDR') ?? forkOverrides?.usdcAddress ?? detectedEntry?.quoteToken,
    'USDC_ADDR'
  );

  const baseDecimals = parseIntEnv(
    'BASE_DECIMALS',
    forkOverrides?.baseDecimals ?? detectedEntry?.baseDecimals ?? 18
  );
  const quoteDecimals = parseIntEnv(
    'QUOTE_DECIMALS',
    forkOverrides?.quoteDecimals ?? detectedEntry?.quoteDecimals ?? 6
  );

  const chainConfig: ChainBackedConfig = {
    ...baseCommon,
    mode,
    baseDecimals,
    quoteDecimals,
    rpcUrl,
    wsUrl,
    chainId: resolvedChainId ?? undefined,
    poolAddress,
    pythAddress,
    hcPxPrecompile,
    hcBboPrecompile,
    hcPxKey,
    hcBboKey,
    hcMarketType,
    hcSizeDecimals,
    hcPxMultiplier,
    baseTokenAddress,
    quoteTokenAddress,
    gasPriceGwei,
    nativeUsd,
    pythPriceId,
    addressBookSource: addressBook ? addressBookPath : undefined
  };

  return chainConfig;
}

export type { ShadowBotConfig } from './types.js';
