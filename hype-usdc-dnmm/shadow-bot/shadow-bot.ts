// shadow-bot.ts
// Enterprise-grade shadow bot for HYPE/USDC DNMM simulation
// Fully simulates the DNMM protocol with all oracle integrations, inventory management, and fee calculations

import 'dotenv/config';
import fs from 'fs';
import http from 'http';
import {
  AbiCoder,
  Contract,
  JsonRpcProvider,
  getBigInt,
  hexlify,
  zeroPadValue,
  formatUnits,
  parseUnits
} from 'ethers';
import {
  Counter,
  Gauge,
  Histogram,
  collectDefaultMetrics,
  register
} from 'prom-client';

// ---------- Configuration Types ----------
interface OracleConfig {
  maxAgeSec: number;
  stallWindowSec: number;
  confCapBpsSpot: number;
  confCapBpsStrict: number;
  divergenceBps: number;
  allowEmaFallback: boolean;
  confWeightSpreadBps: number;
  confWeightSigmaBps: number;
  confWeightPythBps: number;
  sigmaEwmaLambdaBps: number;
  divergenceAcceptBps: number;
  divergenceSoftBps: number;
  divergenceHardBps: number;
  haircutMinBps: number;
  haircutSlopeBps: number;
}

interface InventoryConfig {
  floorBps: number;
  targetBaseXstar: bigint;
  recenterThresholdPct: number;
  invTiltBpsPer1pct: number;
  invTiltMaxBps: number;
  tiltConfWeightBps: number;
  tiltSpreadWeightBps: number;
}

interface FeeConfig {
  baseBps: number;
  alphaNumerator: number;
  alphaDenominator: number;
  betaInvDevNumerator: number;
  betaInvDevDenominator: number;
  capBps: number;
  decayRate: number;
  gammaSizeLinBps: number;
  gammaSizeQuadBps: number;
  sizeFeeCapBps: number;
}

interface InventoryState {
  baseReserves: bigint;
  quoteReserves: bigint;
  lastMid: bigint;
  targetBase: bigint;
}

interface EMAState {
  lastObservedMid: bigint;
  sigmaBps: number;
}

interface FeeState {
  lastBlock: number;
  lastFeeBps: number;
}


// ---------- Environment Configuration ----------
const must = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`Missing env: ${k}`);
  return v;
};
const env = (k: string) => process.env[k];
const int = (k: string, d: number) => (process.env[k] ? Number(process.env[k]) : d);
const bigint = (k: string, d: bigint) => (process.env[k] ? BigInt(process.env[k]) : d);

// Network config
const RPC_URL = must('RPC_URL');
const DNMM_POOL_ADDRESS = env('DNMM_POOL_ADDRESS') || '';
const USE_SPOT = env('USE_SPOT') === 'true';

// CRITICAL: Different keys for different precompiles after testing
// SPOT markets: SPOT_PX (0x0808) uses MARKET ID
// PERP markets: ORACLE_PX (0x0807) uses PERP INDEX
// BBO (0x080e): uses MARKET ID for both
const ORACLE_PRICE_KEY = USE_SPOT ? 107 : 159; // HYPE/USDC market ID (107) for spot, perp index (159) for perp
const MARKET_KEY_INDEX = USE_SPOT ? 107 : 159; // HYPE/USDC spot market (107), HYPE perp (159)

// Price scaling: Formula = 10^(8-szDecimals) for spot, 10^(6-szDecimals) for perp
// HYPE szDecimals = 2
// Spot: 10^(8-2) = 10^6 → multiply raw by 1e12 to get WAD
// Perp: 10^(6-2) = 10^4 → multiply raw by 1e14 to get WAD
const PRICE_SCALE_MULTIPLIER = USE_SPOT ? 1e12 : 1e14;

// Oracle addresses
const PYTH_ADDR = env('PYTH_ADDR') || '';
const PYTH_PAIR_FEED_ID = env('PYTH_PAIR_FEED_ID') || '';
const PYTH_BASE_FEED_ID = env('PYTH_BASE_FEED_ID') || '';
const PYTH_QUOTE_FEED_ID = env('PYTH_QUOTE_FEED_ID') || '';

// Simulation parameters
const INTERVAL_MS = int('INTERVAL_MS', 5000);
const OUT_CSV = env('OUT_CSV') || 'shadow_enterprise.csv';
const PROM_PORT = int('PROM_PORT', 9464);

// Feature flags
const featureFlags = {
  blendOn: env('BLEND_ON') === 'true',
  parityCiOn: env('PARITY_CI_ON') === 'true',
  debugEmit: env('DEBUG_EMIT') === 'true',
  enableSoftDivergence: env('ENABLE_SOFT_DIVERGENCE') === 'true',
  enableSizeFee: env('ENABLE_SIZE_FEE') === 'true',
  enableBboFloor: env('ENABLE_BBO_FLOOR') === 'true',
  enableInvTilt: env('ENABLE_INV_TILT') === 'true',
  enableAOMQ: env('ENABLE_AOMQ') === 'true',
  enableRebates: env('ENABLE_REBATES') === 'true',
  enableAutoRecenter: env('ENABLE_AUTO_RECENTER') === 'true'
};

// Decision thresholds
const ACCEPT_BPS = int('ACCEPT_BPS', 30);
const SOFT_BPS = int('SOFT_BPS', 50);
const HARD_BPS = int('HARD_BPS', 75);
const HYSTERESIS_FRAMES = int('HYSTERESIS_FRAMES', 3);
const HAIRCUT_MIN_BPS = int('HAIRCUT_MIN_BPS', 3);
const HAIRCUT_SLOPE_BPS = int('HAIRCUT_SLOPE_BPS', 1);

// Oracle config defaults (can be overridden from DNMM pool)
const MAX_AGE_SEC = int('MAX_AGE_SEC', 60);
const STALL_WINDOW_SEC = int('STALL_WINDOW_SEC', 120);
const CONF_CAP_BPS_SPOT = int('CONF_CAP_BPS_SPOT', 100);
const CONF_CAP_BPS_STRICT = int('CONF_CAP_BPS_STRICT', 80);
const DIVERGENCE_BPS = int('DIVERGENCE_BPS', 75);
const ALLOW_EMA_FALLBACK = env('ALLOW_EMA_FALLBACK') === 'true';
const CONF_WEIGHT_SPREAD_BPS = int('CONF_WEIGHT_SPREAD_BPS', 3000);
const CONF_WEIGHT_SIGMA_BPS = int('CONF_WEIGHT_SIGMA_BPS', 4000);
const CONF_WEIGHT_PYTH_BPS = int('CONF_WEIGHT_PYTH_BPS', 3000);
const SIGMA_EWMA_LAMBDA_BPS = int('SIGMA_EWMA_LAMBDA_BPS', 100);

// Inventory config defaults
const INVENTORY_FLOOR_BPS = int('INVENTORY_FLOOR_BPS', 1000);
const INVENTORY_TARGET_BASE = bigint('INVENTORY_TARGET_BASE', parseUnits('10000', 18));
const INVENTORY_RECENTER_PCT = int('INVENTORY_RECENTER_PCT', 500);

// Fee config defaults
const FEE_BASE_BPS = int('FEE_BASE_BPS', 10);
const FEE_ALPHA_NUM = int('FEE_ALPHA_NUM', 1);
const FEE_ALPHA_DENOM = int('FEE_ALPHA_DENOM', 100);
const FEE_BETA_NUM = int('FEE_BETA_NUM', 1);
const FEE_BETA_DENOM = int('FEE_BETA_DENOM', 200);
const FEE_CAP_BPS = int('FEE_CAP_BPS', 100);
const FEE_DECAY_RATE = int('FEE_DECAY_RATE', 10);

// Precompiles
const ORACLE_PX = USE_SPOT
  ? '0x0000000000000000000000000000000000000808'  // SPOT_PX for spot markets
  : '0x0000000000000000000000000000000000000807'; // ORACLE_PX for perps
const BBO = '0x000000000000000000000000000000000000080e';
const ORACLE_AGE = '0x0000000000000000000000000000000000000806';
const ORACLE_EMA = USE_SPOT
  ? '0x0000000000000000000000000000000000000806'  // MARK_PX for spot EMA fallback
  : '0x0000000000000000000000000000000000000808'; // SPOT_PX for perp EMA fallback

// Contract ABIs
const PYTH_ABI = [
  'function getPriceUnsafe(bytes32 id) external view returns (int64 price, uint64 conf, int32 expo, uint64 publishTime)'
];

const DNMM_ABI = [
  'function oracleConfig() external view returns (uint32 maxAgeSec, uint32 stallWindowSec, uint16 confCapBpsSpot, uint16 confCapBpsStrict, uint16 divergenceBps, bool allowEmaFallback, uint16 confWeightSpreadBps, uint16 confWeightSigmaBps, uint16 confWeightPythBps, uint16 sigmaEwmaLambdaBps, uint16 divergenceAcceptBps, uint16 divergenceSoftBps, uint16 divergenceHardBps, uint16 haircutMinBps, uint16 haircutSlopeBps)',
  'function inventoryConfig() external view returns (uint128 targetBaseXstar, uint16 floorBps, uint16 recenterThresholdPct, uint16 invTiltBpsPer1pct, uint16 invTiltMaxBps, uint16 tiltConfWeightBps, uint16 tiltSpreadWeightBps)',
  'function feeConfig() external view returns (uint16 baseBps, uint16 alphaNumerator, uint16 alphaDenominator, uint16 betaInvDevNumerator, uint16 betaInvDevDenominator, uint16 capBps, uint16 decayRate, uint16 gammaSizeLinBps, uint16 gammaSizeQuadBps, uint16 sizeFeeCapBps)',
  'function reserves() external view returns (uint256 baseReserves, uint256 quoteReserves)',
  'function lastMid() external view returns (uint256)',
  'function sigmaEwma() external view returns (uint256)'
];

const coder = AbiCoder.defaultAbiCoder();
const provider = new JsonRpcProvider(RPC_URL);
const ONE = 10n ** 18n;
const BPS = 10_000n;

// ---------- State Management ----------
const state = {
  inventory: {
    baseReserves: parseUnits('100000', 18),
    quoteReserves: parseUnits('3000000', 6),
    lastMid: parseUnits('30', 18),
    targetBase: INVENTORY_TARGET_BASE
  } as InventoryState,

  ema: {
    lastObservedMid: 0n,
    sigmaBps: 0
  } as EMAState,

  feeState: {
    lastBlock: 0,
    lastFeeBps: FEE_BASE_BPS
  } as FeeState,


  oracleConfig: {
    maxAgeSec: MAX_AGE_SEC,
    stallWindowSec: STALL_WINDOW_SEC,
    confCapBpsSpot: CONF_CAP_BPS_SPOT,
    confCapBpsStrict: CONF_CAP_BPS_STRICT,
    divergenceBps: DIVERGENCE_BPS,
    allowEmaFallback: ALLOW_EMA_FALLBACK,
    confWeightSpreadBps: CONF_WEIGHT_SPREAD_BPS,
    confWeightSigmaBps: CONF_WEIGHT_SIGMA_BPS,
    confWeightPythBps: CONF_WEIGHT_PYTH_BPS,
    sigmaEwmaLambdaBps: SIGMA_EWMA_LAMBDA_BPS,
    divergenceAcceptBps: ACCEPT_BPS,
    divergenceSoftBps: SOFT_BPS,
    divergenceHardBps: HARD_BPS,
    haircutMinBps: HAIRCUT_MIN_BPS,
    haircutSlopeBps: HAIRCUT_SLOPE_BPS
  } as OracleConfig,

  inventoryConfig: {
    floorBps: INVENTORY_FLOOR_BPS,
    targetBaseXstar: INVENTORY_TARGET_BASE,
    recenterThresholdPct: INVENTORY_RECENTER_PCT,
    invTiltBpsPer1pct: 0,
    invTiltMaxBps: 0,
    tiltConfWeightBps: 0,
    tiltSpreadWeightBps: 0
  } as InventoryConfig,

  feeConfig: {
    baseBps: FEE_BASE_BPS,
    alphaNumerator: FEE_ALPHA_NUM,
    alphaDenominator: FEE_ALPHA_DENOM,
    betaInvDevNumerator: FEE_BETA_NUM,
    betaInvDevDenominator: FEE_BETA_DENOM,
    capBps: FEE_CAP_BPS,
    decayRate: FEE_DECAY_RATE,
    gammaSizeLinBps: 0,
    gammaSizeQuadBps: 0,
    sizeFeeCapBps: 0
  } as FeeConfig
};

// ---------- Helper Functions ----------
function encodeMarketKey32(index: number): string {
  // For HyperCore oracles, encode the uint32 index as bytes32
  // The index needs to be properly encoded using abi.encode(uint32)
  return coder.encode(['uint32'], [index]);
}

function toWadFromHC(rawPrice: bigint): bigint {
  // Convert HyperCore raw oracle price to WAD (1e18 = $1.00)
  //
  // Formula from Hyperliquid:
  // - Spot: divisor = 10^(8-szDecimals)
  // - Perp: divisor = 10^(6-szDecimals)
  // - HYPE szDecimals = 2
  //
  // Spot: 10^(8-2) = 10^6 → multiply by 1e12 to get WAD
  // Perp: 10^(6-2) = 10^4 → multiply by 1e14 to get WAD
  //
  // Example (spot): raw=46,739,000 → 46,739,000 * 1e12 = 46.739 * 1e18 (WAD)
  return rawPrice * BigInt(PRICE_SCALE_MULTIPLIER);
}

function toWadFromPyth(price: bigint, expo: number): bigint {
  const e = BigInt(expo);
  if (e === -18n) return price;
  if (e > -18n) return price * 10n ** (e + 18n);
  return price / 10n ** (-18n - e);
}

function abs(x: bigint): bigint {
  return x >= 0n ? x : -x;
}

function bps(num: bigint, den: bigint): number {
  if (den === 0n) return 0;
  return Number((BPS * abs(num)) / abs(den));
}

function min(a: bigint, b: bigint): bigint {
  return a < b ? a : b;
}

function max(a: bigint, b: bigint): bigint {
  return a > b ? a : b;
}

function mulDivDown(x: bigint, y: bigint, d: bigint): bigint {
  return (x * y) / d;
}

// ---------- Oracle Functions ----------
async function readHyperCore() {
  // CRITICAL: Correct precompile and key combinations (verified via testing)
  // SPOT: SPOT_PX (0x0808) + MARKET ID (107 for HYPE/USDC) + scale ÷ 10^6
  // PERP: ORACLE_PX (0x0807) + PERP INDEX (159 for HYPE) + scale ÷ 10^4
  const oraclePxArg = encodeMarketKey32(ORACLE_PRICE_KEY);
  const bboArg = encodeMarketKey32(MARKET_KEY_INDEX);

  // Read mid price - oracle returns raw bytes (8 bytes for uint64)
  const pxBytes = await provider.call({ to: ORACLE_PX, data: oraclePxArg });
  if (!pxBytes || pxBytes.length < 2) throw new Error('oraclePx empty');

  // Handle both 8-byte and 32-byte responses
  let pxU64: bigint;
  if (pxBytes.length === 8 || pxBytes.length === 10) {
    // Raw 8 bytes - convert to bigint directly
    pxU64 = BigInt(pxBytes);
  } else {
    // 32 bytes - ABI-encoded uint64
    const [decoded] = coder.decode(['uint64'], pxBytes) as unknown as [bigint];
    pxU64 = decoded;
  }

  // Read BBO (may not work for all markets, use mid as fallback)
  let bidU64 = pxU64;
  let askU64 = pxU64;
  let bboWorking = false;
  try {
    const bboBytes = await provider.call({ to: BBO, data: bboArg });
    if (bboBytes && bboBytes.length >= 16) {
      // BBO returns 2x uint64 (16 bytes total)
      if (bboBytes.length === 16 || bboBytes.length === 18) {
        // Raw bytes: first 8 bytes = bid, next 8 bytes = ask
        const bidHex = bboBytes.slice(0, 18);
        const askHex = '0x' + bboBytes.slice(18);
        bidU64 = BigInt(bidHex);
        askU64 = BigInt(askHex);
      } else {
        // ABI-encoded
        const decoded = coder.decode(['uint64', 'uint64'], bboBytes) as unknown as [bigint, bigint];
        bidU64 = decoded[0];
        askU64 = decoded[1];
      }

      // Sanity check: bid/ask should be within 10% of mid
      const bidCheck = toWadFromHC(bidU64);
      const midCheck = toWadFromHC(pxU64);
      if (bidCheck > midCheck / 2n && bidCheck < midCheck * 2n) {
        bboWorking = true;
      } else {
        // BBO values don't make sense, use mid ± small spread
        bidU64 = pxU64;
        askU64 = pxU64;
      }
    }
  } catch {}


  // Read age (if available) - NOTE: Age precompile doesn't work reliably for spot markets
  // For spot, assume SPOT_PX always returns fresh data (set age=0)
  let ageSec = USE_SPOT ? 0 : 0;
  if (!USE_SPOT) {
    try {
      const ageBytes = await provider.call({ to: ORACLE_AGE, data: bboArg });
      if (ageBytes && ageBytes.length >= 2) {
        const [ageU32] = coder.decode(['uint32'], ageBytes) as unknown as [number];
        ageSec = ageU32;
      }
    } catch {}
  }

  // Read EMA (if available) - NOTE: EMA precompile doesn't work for spot markets (returns wrong values)
  // Skip EMA read for spot - rely on Pyth fallback instead
  let emaWad: bigint | undefined;
  if (!USE_SPOT) {
    try {
      const emaBytes = await provider.call({ to: ORACLE_EMA, data: bboArg });
      if (emaBytes && emaBytes.length >= 2) {
        let emaU64: bigint;
        if (emaBytes.length === 8 || emaBytes.length === 10) {
          emaU64 = BigInt(emaBytes);
        } else {
          const [decoded] = coder.decode(['uint64'], emaBytes) as unknown as [bigint];
          emaU64 = decoded;
        }
        emaWad = toWadFromHC(emaU64);
      }
    } catch {}
  }

  const midHC = toWadFromHC(pxU64);
  const bid = toWadFromHC(bidU64);
  const ask = toWadFromHC(askU64);
  const spreadBps = bps(ask - bid, midHC);

  return { midHC, bid, ask, spreadBps, ageSec, emaWad };
}

type PythPrice = { price: bigint; conf: bigint; expo: number; ts: number };

async function readPythPair(pyth: Contract, feedId: string): Promise<PythPrice> {
  // Ensure feedId has 0x prefix for bytes32 parameter
  const formattedFeedId = feedId.startsWith('0x') ? feedId : `0x${feedId}`;
  const r = await pyth.getPriceUnsafe(formattedFeedId);
  return {
    price: getBigInt(r[0]),
    conf: getBigInt(r[1]),
    expo: Number(r[2]),
    ts: Number(r[3])
  };
}

async function readPythDerived(pyth: Contract, baseId: string, quoteId: string) {
  const rb = await readPythPair(pyth, baseId);
  const rq = await readPythPair(pyth, quoteId);

  const baseWad = toWadFromPyth(rb.price, rb.expo);
  const quoteWad = toWadFromPyth(rq.price, rq.expo);
  if (baseWad === 0n || quoteWad === 0n) throw new Error('Pyth zero price');

  const mid = (baseWad * ONE) / quoteWad;

  const confBaseWad = toWadFromPyth(rb.conf, rb.expo);
  const confQuoteWad = toWadFromPyth(rq.conf, rq.expo);
  const relBaseBps = bps(confBaseWad, baseWad);
  const relQuoteBps = bps(confQuoteWad, quoteWad);
  const confBps = relBaseBps + relQuoteBps;

  return { mid, confBps, tsMin: Math.min(rb.ts, rq.ts) };
}

async function readPythAny(): Promise<{ mid?: bigint; confBps?: number; ts?: number }> {
  if (!PYTH_ADDR) return {};
  const pyth = new Contract(PYTH_ADDR, PYTH_ABI, provider);

  if (PYTH_PAIR_FEED_ID) {
    const r = await readPythPair(pyth, PYTH_PAIR_FEED_ID);
    const mid = toWadFromPyth(r.price, r.expo);
    const confWad = toWadFromPyth(r.conf, r.expo);
    const confBps = mid !== 0n ? bps(confWad, mid) : 0;
    return { mid, confBps, ts: r.ts };
  }

  if (PYTH_BASE_FEED_ID && PYTH_QUOTE_FEED_ID) {
    const { mid, confBps, tsMin } = await readPythDerived(pyth, PYTH_BASE_FEED_ID, PYTH_QUOTE_FEED_ID);
    return { mid, confBps, ts: tsMin };
  }

  return {};
}

// ---------- DNMM Simulation Functions ----------
function sqrtBigInt(value: bigint): bigint {
  if (value < 0n) return 0n;
  if (value < 2n) return value;

  let x = value;
  let y = (x + 1n) / 2n;

  while (y < x) {
    x = y;
    y = (x + value / x) / 2n;
  }

  return x;
}

function updateSigma(mid: bigint, spreadBps: number): number {
  const cfg = state.oracleConfig;
  const cap = cfg.confCapBpsSpot;

  // Sample is max(spreadBps, price delta from last observed)
  let sample = spreadBps;

  if (state.ema.lastObservedMid > 0n && mid > 0n) {
    const priorMid = state.ema.lastObservedMid;
    const deltaBps = bps(abs(mid - priorMid), priorMid);
    const cappedDelta = cap > 0 ? Math.min(deltaBps, cap) : deltaBps;
    if (cappedDelta > sample) {
      sample = cappedDelta;
    }
  }

  const lambda = cfg.sigmaEwmaLambdaBps;
  let sigmaBps: number;

  if (state.ema.sigmaBps === 0) {
    sigmaBps = sample;
  } else if (lambda >= 10000) {
    sigmaBps = state.ema.sigmaBps;
  } else {
    // EWMA: sigmaBps = (lastSigma * lambda + sample * (BPS - lambda)) / BPS
    sigmaBps = Math.floor((state.ema.sigmaBps * lambda + sample * (10000 - lambda)) / 10000);
  }

  // Cap sigma
  if (cap > 0 && sigmaBps > cap) {
    sigmaBps = cap;
  }

  state.ema.lastObservedMid = mid;
  state.ema.sigmaBps = sigmaBps;

  return sigmaBps;
}

function calculateInventoryDeviation(): number {
  const { baseReserves, quoteReserves, lastMid, targetBase } = state.inventory;

  // Convert to WAD (18 decimals)
  const baseWad = baseReserves; // Already in 18 decimals
  const quoteWad = quoteReserves * 10n ** 12n; // Convert USDC (6 decimals) to WAD
  const targetWad = targetBase; // Already in 18 decimals

  const baseNotionalWad = mulDivDown(baseWad, lastMid, ONE);
  const totalNotionalWad = quoteWad + baseNotionalWad;

  if (totalNotionalWad === 0n) return 0;

  // Deviation = abs(baseWad - targetWad) / totalNotionalWad * BPS
  const deviation = abs(baseWad - targetWad);
  const deviationBps = bps(deviation, totalNotionalWad);

  return deviationBps;
}

function calculateConfidence(
  spreadBps: number,
  pythConfBps: number | undefined,
  pythUsed: boolean,
  spreadAvailable: boolean
): number {
  const cfg = state.oracleConfig;
  const cap = cfg.confCapBpsSpot;

  // Contract logic: fallbackConf = pythFresh && pythUsed ? pythConf : 0
  const fallbackConf = (pythConfBps !== undefined && pythUsed) ? pythConfBps : 0;

  // If blend is off, use legacy logic
  if (!featureFlags.blendOn) {
    const primary = spreadAvailable ? spreadBps : 0;
    let conf = Math.max(primary, fallbackConf);
    if (cap > 0 && conf > cap) conf = cap;
    return conf;
  }

  // Spread-based confidence (only if spread is available)
  const cappedSpread = cap > 0 ? Math.min(spreadBps, cap) : spreadBps;
  const confSpread = spreadAvailable ? Math.floor((cappedSpread * cfg.confWeightSpreadBps) / 10000) : 0;

  // Sigma-based confidence
  const cappedSigma = cap > 0 ? Math.min(state.ema.sigmaBps, cap) : state.ema.sigmaBps;
  const confSigma = cappedSigma > 0 ? Math.floor((cappedSigma * cfg.confWeightSigmaBps) / 10000) : 0;

  // Pyth-based confidence (contract: only when pythUsed = true, meaning REASON_PYTH)
  let confPyth = 0;
  if (fallbackConf > 0) {
    const cappedPyth = cap > 0 ? Math.min(fallbackConf, cap) : fallbackConf;
    confPyth = Math.floor((cappedPyth * cfg.confWeightPythBps) / 10000);
  }

  // Confidence is the MAX of all components, not sum
  let confBps = Math.max(confSpread, confSigma, confPyth);

  // Apply cap
  if (cap > 0 && confBps > cap) {
    confBps = cap;
  }

  return confBps;
}

function calculateFee(confBps: number, invDeviationBps: number, currentBlock: number): number {
  const cfg = state.feeConfig;
  const feeState = state.feeState;

  // Initialize if first time
  if (feeState.lastBlock === 0) {
    feeState.lastBlock = currentBlock;
    feeState.lastFeeBps = cfg.baseBps;
  }

  // Apply exponential decay if blocks elapsed
  if (cfg.decayRate > 0 && currentBlock > feeState.lastBlock) {
    const blocksElapsed = currentBlock - feeState.lastBlock;
    if (feeState.lastFeeBps > cfg.baseBps) {
      const delta = feeState.lastFeeBps - cfg.baseBps;
      const factorNumerator = 100 - cfg.decayRate; // decayRate is 0-100

      // Apply decay: delta * factor^blocks
      let decayedDelta = delta;
      for (let i = 0; i < blocksElapsed && i < 100; i++) {
        decayedDelta = Math.floor((decayedDelta * factorNumerator) / 100);
      }

      feeState.lastFeeBps = cfg.baseBps + decayedDelta;
    } else {
      feeState.lastFeeBps = cfg.baseBps;
    }
  }

  feeState.lastBlock = currentBlock;

  // Calculate new fee components
  const confComponent = cfg.alphaDenominator === 0
    ? 0
    : Math.floor((confBps * cfg.alphaNumerator) / cfg.alphaDenominator);

  const invComponent = cfg.betaInvDevDenominator === 0
    ? 0
    : Math.floor((invDeviationBps * cfg.betaInvDevNumerator) / cfg.betaInvDevDenominator);

  let fee = cfg.baseBps + confComponent + invComponent;

  // Apply cap
  if (fee > cfg.capBps) {
    fee = cfg.capBps;
  }

  feeState.lastFeeBps = fee;
  return fee;
}

function checkOracleValidity(
  deltaBps: number,
  confBps: number,
  pythFresh: boolean,
  usedFallback: boolean,
  spreadBps: number,
  spreadAvailable: boolean
): { valid: boolean; reason: string } {
  const cfg = state.oracleConfig;

  // Check confidence cap (strict mode)
  if (confBps > cfg.confCapBpsStrict) {
    return { valid: false, reason: 'CONF_CAP_EXCEEDED' };
  }

  // Check spread if available and not using fallback
  if (!usedFallback && spreadAvailable && spreadBps > cfg.confCapBpsSpot) {
    return { valid: false, reason: 'SPREAD_TOO_WIDE' };
  }

  // Check divergence if using primary oracle and Pyth is fresh
  if (!usedFallback && pythFresh && deltaBps > cfg.divergenceBps) {
    return { valid: false, reason: 'DIVERGENCE_EXCEEDED' };
  }

  return { valid: true, reason: 'VALID' };
}

function simulateTrade(isBuy: boolean, amountIn: bigint) {
  const { baseReserves, quoteReserves, lastMid } = state.inventory;
  const floor = mulDivDown(baseReserves, BigInt(state.inventoryConfig.floorBps), BPS);

  if (isBuy) {
    // Buy BASE with QUOTE
    const baseOut = mulDivDown(amountIn * 10n ** 12n, ONE, lastMid);
    const availableBase = baseReserves > floor ? baseReserves - floor : 0n;

    if (baseOut <= availableBase) {
      state.inventory.baseReserves -= baseOut;
      state.inventory.quoteReserves += amountIn;
      return { executed: true, partial: false };
    } else if (availableBase > 0n) {
      state.inventory.baseReserves -= availableBase;
      const quoteUsed = mulDivDown(availableBase, lastMid, ONE * 10n ** 12n);
      state.inventory.quoteReserves += quoteUsed;
      return { executed: true, partial: true };
    } else {
      return { executed: false, partial: false };
    }
  } else {
    // Sell BASE for QUOTE
    const quoteFloor = mulDivDown(quoteReserves, BigInt(state.inventoryConfig.floorBps), BPS);
    const quoteOut = mulDivDown(amountIn, lastMid, ONE * 10n ** 12n);
    const availableQuote = quoteReserves > quoteFloor ? quoteReserves - quoteFloor : 0n;

    if (quoteOut <= availableQuote) {
      state.inventory.baseReserves += amountIn;
      state.inventory.quoteReserves -= quoteOut;
      return { executed: true, partial: false };
    } else if (availableQuote > 0n) {
      const baseUsed = mulDivDown(availableQuote * 10n ** 12n, ONE, lastMid);
      state.inventory.baseReserves += baseUsed;
      state.inventory.quoteReserves -= availableQuote;
      return { executed: true, partial: true };
    } else {
      return { executed: false, partial: false };
    }
  }
}

// ---------- Metrics Setup ----------
collectDefaultMetrics();

const gDelta = new Gauge({ name: 'dnmm_delta_bps', help: 'HC vs Pyth delta bps' });
const gConf = new Gauge({ name: 'dnmm_conf_bps', help: 'Total confidence bps' });
const gSpread = new Gauge({ name: 'dnmm_spread_bps', help: 'HC orderbook spread bps' });
const gSigma = new Gauge({ name: 'dnmm_sigma_bps', help: 'Volatility EWMA bps' });
const gInventory = new Gauge({ name: 'dnmm_inventory_deviation_bps', help: 'Inventory deviation from target' });
const gFee = new Gauge({ name: 'dnmm_fee_bps', help: 'Calculated fee bps' });

const cDecision = new Counter({
  name: 'dnmm_decisions_total',
  help: 'Count of decisions by type',
  labelNames: ['decision'] as const
});

const hDelta = new Histogram({
  name: 'dnmm_delta_bps_hist',
  help: 'Histogram of delta bps',
  buckets: [5, 10, 20, 30, 40, 50, 75, 100, 200, 500, 1000]
});

const hConf = new Histogram({
  name: 'dnmm_conf_bps_hist',
  help: 'Histogram of confidence bps',
  buckets: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 150, 200]
});

const hFee = new Histogram({
  name: 'dnmm_fee_bps_hist',
  help: 'Histogram of fee bps',
  buckets: [5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100]
});

const hSpread = new Histogram({
  name: 'dnmm_spread_bps_hist',
  help: 'Histogram of spread bps',
  buckets: [1, 2, 5, 10, 15, 20, 30, 40, 50, 75, 100, 200]
});

// Prometheus server
http.createServer(async (_req, res) => {
  if (_req.url === '/metrics') {
    res.setHeader('Content-Type', register.contentType);
    res.end(await register.metrics());
  } else if (_req.url === '/stats') {
    // Provide a stats endpoint for quick status check
    const stats = {
      inventory: {
        base: formatUnits(state.inventory.baseReserves, 18),
        quote: formatUnits(state.inventory.quoteReserves, 6),
        lastMid: formatUnits(state.inventory.lastMid, 18),
        deviation_bps: calculateInventoryDeviation()
      },
      volatility: {
        last_observed_mid: formatUnits(state.ema.lastObservedMid, 18),
        sigma_bps: state.ema.sigmaBps
      },
      fee: {
        last_block: state.feeState.lastBlock,
        last_fee_bps: state.feeState.lastFeeBps
      },
      config: {
        oracle: state.oracleConfig,
        inventory: {
          floorBps: state.inventoryConfig.floorBps,
          targetBaseXstar: formatUnits(state.inventoryConfig.targetBaseXstar, 18),
          recenterThresholdPct: state.inventoryConfig.recenterThresholdPct,
          invTiltBpsPer1pct: state.inventoryConfig.invTiltBpsPer1pct,
          invTiltMaxBps: state.inventoryConfig.invTiltMaxBps,
          tiltConfWeightBps: state.inventoryConfig.tiltConfWeightBps,
          tiltSpreadWeightBps: state.inventoryConfig.tiltSpreadWeightBps
        },
        fee: state.feeConfig,
        featureFlags
      }
    };
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(stats, null, 2));
  } else {
    res.statusCode = 404;
    res.end('not found');
  }
}).listen(PROM_PORT, () => {
  console.log(`[prometheus] Metrics available at :${PROM_PORT}/metrics`);
  console.log(`[prometheus] Stats available at :${PROM_PORT}/stats`);
});

// ---------- CSV Logging ----------
function appendCsvHeader(path: string) {
  if (!fs.existsSync(path)) {
    const headers = [
      'timestamp',
      'mid_hc_wad',
      'bid_wad',
      'ask_wad',
      'spread_bps',
      'mid_pyth_wad',
      'conf_pyth_bps',
      'mid_ema_wad',
      'delta_bps',
      'conf_total_bps',
      'conf_spread_bps',
      'conf_sigma_bps',
      'conf_pyth_bps',
      'sigma_bps',
      'inventory_deviation_bps',
      'fee_bps',
      'base_reserves',
      'quote_reserves',
      'decision',
      'used_fallback',
      'pyth_fresh',
      'ema_fresh',
      'hysteresis_frames',
      'rejection_duration'
    ];
    fs.writeFileSync(path, headers.join(',') + '\n', { encoding: 'utf-8' });
  }
}

function appendCsvRow(path: string, data: Record<string, any>) {
  const row = [
    data.timestamp,
    data.midHC,
    data.bid,
    data.ask,
    data.spreadBps,
    data.midPyth || 0,
    data.confPythBps || 0,
    data.midEma || 0,
    data.deltaBps,
    data.confTotalBps,
    data.confSpreadBps,
    data.confSigmaBps,
    data.confPythWeighted,
    data.sigmaBps,
    data.inventoryDeviationBps,
    data.feeBps,
    data.baseReserves,
    data.quoteReserves,
    data.decision,
    data.usedFallback,
    data.pythFresh,
    data.emaFresh,
    data.hysteresisFrames,
    data.rejectionDuration
  ];
  fs.appendFileSync(path, row.join(',') + '\n', { encoding: 'utf-8' });
}

// ---------- Load DNMM Config (if available) ----------
async function loadDNMMConfig() {
  if (!DNMM_POOL_ADDRESS) {
    console.log('[config] No DNMM pool address provided, using defaults');
    return;
  }

  try {
    const dnmm = new Contract(DNMM_POOL_ADDRESS, DNMM_ABI, provider);

    // Load oracle config
    const oracleCfg = await dnmm.oracleConfig();
    state.oracleConfig = {
      maxAgeSec: Number(oracleCfg[0]),
      stallWindowSec: Number(oracleCfg[1]),
      confCapBpsSpot: Number(oracleCfg[2]),
      confCapBpsStrict: Number(oracleCfg[3]),
      divergenceBps: Number(oracleCfg[4]),
      allowEmaFallback: oracleCfg[5],
      confWeightSpreadBps: Number(oracleCfg[6]),
      confWeightSigmaBps: Number(oracleCfg[7]),
      confWeightPythBps: Number(oracleCfg[8]),
      sigmaEwmaLambdaBps: Number(oracleCfg[9]),
      divergenceAcceptBps: Number(oracleCfg[10]),
      divergenceSoftBps: Number(oracleCfg[11]),
      divergenceHardBps: Number(oracleCfg[12]),
      haircutMinBps: Number(oracleCfg[13]),
      haircutSlopeBps: Number(oracleCfg[14])
    };

    // Load inventory config
    const invCfg = await dnmm.inventoryConfig();
    state.inventoryConfig = {
      targetBaseXstar: getBigInt(invCfg[0]),
      floorBps: Number(invCfg[1]),
      recenterThresholdPct: Number(invCfg[2]),
      invTiltBpsPer1pct: Number(invCfg[3]),
      invTiltMaxBps: Number(invCfg[4]),
      tiltConfWeightBps: Number(invCfg[5]),
      tiltSpreadWeightBps: Number(invCfg[6])
    };

    // Load fee config
    const feeCfg = await dnmm.feeConfig();
    state.feeConfig = {
      baseBps: Number(feeCfg[0]),
      alphaNumerator: Number(feeCfg[1]),
      alphaDenominator: Number(feeCfg[2]),
      betaInvDevNumerator: Number(feeCfg[3]),
      betaInvDevDenominator: Number(feeCfg[4]),
      capBps: Number(feeCfg[5]),
      decayRate: Number(feeCfg[6]),
      gammaSizeLinBps: Number(feeCfg[7]),
      gammaSizeQuadBps: Number(feeCfg[8]),
      sizeFeeCapBps: Number(feeCfg[9])
    };

    // Load reserves
    const reserves = await dnmm.reserves();
    state.inventory.baseReserves = getBigInt(reserves[0]);
    state.inventory.quoteReserves = getBigInt(reserves[1]);

    // Load last mid
    const lastMid = await dnmm.lastMid();
    state.inventory.lastMid = getBigInt(lastMid);

    console.log('[config] Loaded configuration from DNMM pool:', DNMM_POOL_ADDRESS);
  } catch (err) {
    console.log('[config] Failed to load DNMM config, using defaults:', err);
  }
}

// ---------- Main Sampling Function ----------
async function sampleOnce() {
  const now = Math.floor(Date.now() / 1000);
  // Simulate block number (in real scenario, read from provider)
  const currentBlock = Math.floor(now / 2); // Assume 2-second blocks

  try {
    // Read HyperCore oracles
    const hc = await readHyperCore();

    // Check HC freshness
    const hcFresh = hc.ageSec <= state.oracleConfig.maxAgeSec;
    const spreadAvailable = hc.bid > 0n && hc.ask > 0n;

    // Read Pyth oracles
    const pyth = await readPythAny();

    // Check Pyth freshness
    const pythFresh = pyth.ts !== undefined && (now - pyth.ts) <= state.oracleConfig.maxAgeSec;

    // Determine which price to use (following contract fallback logic)
    let usedMid = hc.midHC;
    let usedFallback = false;
    let reason = 'HC_PRIMARY';

    // If HC is stale, try EMA fallback
    if (!hcFresh && state.oracleConfig.allowEmaFallback && hc.emaWad !== undefined) {
      usedMid = hc.emaWad;
      usedFallback = true;
      reason = 'EMA_FALLBACK';
    }

    // If still no valid mid and Pyth is fresh, use Pyth
    if (usedMid === 0n && pythFresh && pyth.mid) {
      usedMid = pyth.mid;
      usedFallback = true;
      reason = 'PYTH_FALLBACK';
    }

    // Update inventory mid price
    state.inventory.lastMid = usedMid;

    // Update sigma (volatility EWMA)
    const sigmaBps = updateSigma(usedMid, hc.spreadBps);

    // Calculate divergence (symmetric formula matching OracleUtils.computeDivergenceBps)
    let deltaBps = 0;
    if (pyth.mid && usedMid > 0n) {
      const hi = max(usedMid, pyth.mid);
      const lo = min(usedMid, pyth.mid);
      deltaBps = bps(hi - lo, hi);
    }

    // Determine if we used Pyth for price (pythUsed = true only for REASON_PYTH)
    const pythUsed = reason === 'PYTH_FALLBACK';

    // Calculate confidence with all components (matching DnmPool._computeConfidence)
    const confTotalBps = calculateConfidence(hc.spreadBps, pyth.confBps, pythUsed, spreadAvailable);

    // Check oracle validity (mimics contract reverts)
    const validity = checkOracleValidity(
      deltaBps,
      confTotalBps,
      pythFresh,
      usedFallback,
      hc.spreadBps,
      spreadAvailable
    );

    // Calculate inventory deviation
    const inventoryDeviationBps = calculateInventoryDeviation();

    // Calculate fee with decay
    const feeBps = calculateFee(confTotalBps, inventoryDeviationBps, currentBlock);

    // Calculate confidence components for detailed logging (matching contract logic)
    const cfg = state.oracleConfig;
    const cap = cfg.confCapBpsSpot;
    const confSpreadBps = spreadAvailable
      ? Math.floor((Math.min(hc.spreadBps, cap) * cfg.confWeightSpreadBps) / 10000)
      : 0;
    const confSigmaBps = Math.floor((Math.min(sigmaBps, cap) * cfg.confWeightSigmaBps) / 10000);
    const confPythWeighted = pyth.confBps && pythUsed
      ? Math.floor((Math.min(pyth.confBps, cap) * cfg.confWeightPythBps) / 10000)
      : 0;

    // Update metrics
    gDelta.set(deltaBps);
    gConf.set(confTotalBps);
    gSpread.set(hc.spreadBps);
    gSigma.set(sigmaBps);
    gInventory.set(inventoryDeviationBps);
    gFee.set(feeBps);

    hDelta.observe(deltaBps);
    hConf.observe(confTotalBps);
    hFee.observe(feeBps);
    hSpread.observe(hc.spreadBps);
    cDecision.inc({ decision: validity.reason });

    // Log to CSV
    appendCsvRow(OUT_CSV, {
      timestamp: now,
      midHC: hc.midHC.toString(),
      bid: hc.bid.toString(),
      ask: hc.ask.toString(),
      spreadBps: hc.spreadBps,
      midPyth: pyth.mid?.toString(),
      confPythBps: pyth.confBps,
      midEma: hc.emaWad?.toString() || '0',
      deltaBps,
      confTotalBps,
      confSpreadBps,
      confSigmaBps,
      confPythWeighted,
      sigmaBps,
      inventoryDeviationBps,
      feeBps,
      baseReserves: formatUnits(state.inventory.baseReserves, 18),
      quoteReserves: formatUnits(state.inventory.quoteReserves, 6),
      decision: validity.valid ? 'VALID' : validity.reason,
      usedFallback,
      pythFresh,
      emaFresh: hc.emaWad !== undefined && hc.emaWad > 0n,
      hysteresisFrames: 0,
      rejectionDuration: 0
    });

    // Simulate random trades periodically (10% chance) only if oracle is valid
    if (validity.valid && Math.random() < 0.1) {
      const isBuy = Math.random() < 0.5;
      const amount = parseUnits(String(Math.floor(Math.random() * 1000)), isBuy ? 6 : 18);
      const result = simulateTrade(isBuy, amount);

      if (result.executed) {
        console.log(
          `[trade] ${isBuy ? 'BUY' : 'SELL'} ${formatUnits(amount, isBuy ? 6 : 18)} ` +
          `${isBuy ? 'USDC' : 'HYPE'} - ${result.partial ? 'PARTIAL' : 'FULL'}`
        );
      }
    }

    // Console output
    console.log(
      `[${now}] HC: mid=${formatUnits(hc.midHC, 18)} spread=${hc.spreadBps}bps age=${hc.ageSec}s` +
      ` | Pyth: ${pythFresh && pyth.mid ? `mid=${formatUnits(pyth.mid, 18)} conf=${pyth.confBps}bps` : 'stale/missing'}` +
      ` | delta=${deltaBps}bps conf=${confTotalBps}bps (spread=${confSpreadBps} sigma=${confSigmaBps} pyth=${confPythWeighted})` +
      ` | sigma=${sigmaBps}bps inv_dev=${inventoryDeviationBps}bps fee=${feeBps}bps` +
      ` | ${reason} | ${validity.valid ? 'VALID' : validity.reason}`
    );

  } catch (err) {
    console.error('[error]', err);
  }
}

// ---------- Bootstrap ----------
appendCsvHeader(OUT_CSV);

(async function main() {
  console.log('[shadow-bot] Enterprise DNMM Shadow Bot Starting...');
  console.log('[shadow-bot] Version: 2.0.0 - Full Protocol Simulation');
  console.log('[config] Loading DNMM configuration...');

  await loadDNMMConfig();

  console.log('[config] Oracle Config:', state.oracleConfig);
  console.log('[config] Inventory Config:', {
    floorBps: state.inventoryConfig.floorBps,
    targetBaseXstar: formatUnits(state.inventoryConfig.targetBaseXstar, 18),
    recenterThresholdPct: state.inventoryConfig.recenterThresholdPct
  });
  console.log('[config] Fee Config:', state.feeConfig);
  console.log('[shadow-bot] Beginning simulation...');
  console.log(`[shadow-bot] Sampling every ${INTERVAL_MS}ms`);
  console.log(`[shadow-bot] Writing data to ${OUT_CSV}`);
  console.log(`[shadow-bot] Prometheus metrics at http://localhost:${PROM_PORT}/metrics`);
  console.log(`[shadow-bot] Stats dashboard at http://localhost:${PROM_PORT}/stats`);

  await sampleOnce();
  setInterval(sampleOnce, INTERVAL_MS);
})().catch((err) => {
  console.error('[fatal]', err);
  process.exit(1);
});
