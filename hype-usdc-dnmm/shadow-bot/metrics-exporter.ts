/**
 * DNMM L3 Shadow Bot Metrics Exporter
 *
 * Collects metrics from DnmPool events and on-chain state every 500ms
 * Exports to Prometheus for dashboard visualization and alerting
 *
 * Spec: DNMM_L3_HYBRID_UPGRADE.json - shadowbot_metrics_spec
 */

import { ethers } from 'ethers';
import { Registry, Gauge, Counter, Histogram } from 'prom-client';

// ═══════════════════════════════════════════════════════════════════════════
// Configuration
// ═══════════════════════════════════════════════════════════════════════════

interface MetricsConfig {
  rpcUrl: string;
  dnmPoolAddress: string;
  pythOracleAddress: string;
  hcOracleAddress: string;
  pythPriceIdHype: string;
  pythPriceIdUsdc: string;
  collectIntervalMs: number;
  prometheusPort: number;
}

const config: MetricsConfig = {
  rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
  dnmPoolAddress: process.env.DNMM_POOL_ADDRESS || '',
  pythOracleAddress: process.env.PYTH_ORACLE || '',
  hcOracleAddress: process.env.HC_ORACLE || '',
  pythPriceIdHype: process.env.PYTH_PRICE_ID_HYPE || '',
  pythPriceIdUsdc: process.env.PYTH_PRICE_ID_USDC || '',
  collectIntervalMs: parseInt(process.env.COLLECT_INTERVAL_MS || '500'),
  prometheusPort: parseInt(process.env.PROM_PORT || '9090'),
};

// ═══════════════════════════════════════════════════════════════════════════
// Prometheus Registry
// ═══════════════════════════════════════════════════════════════════════════

const register = new Registry();

// Oracle Metrics
const deltaBps = new Gauge({
  name: 'dnmm_delta_bps',
  help: '10000 * |HC.mid - Pyth.mid| / Pyth.mid',
  registers: [register],
});

const pythConfBps = new Gauge({
  name: 'dnmm_pyth_conf_bps',
  help: '10000 * conf / price',
  registers: [register],
});

const hcSpreadBps = new Gauge({
  name: 'dnmm_hc_spread_bps',
  help: '10000 * (ask - bid) / mid',
  registers: [register],
});

// Decision Metrics
const decisionCounter = new Counter({
  name: 'dnmm_decision_total',
  help: 'Count of quote decisions by type',
  labelNames: ['decision'],
  registers: [register],
});

// Fee Metrics
const feeAskBps = new Gauge({
  name: 'dnmm_fee_ask_bps',
  help: 'Final ask fee applied (bps)',
  registers: [register],
});

const feeBidBps = new Gauge({
  name: 'dnmm_fee_bid_bps',
  help: 'Final bid fee applied (bps)',
  registers: [register],
});

// Size Metrics
const sizeBucketCounter = new Counter({
  name: 'dnmm_size_bucket_total',
  help: 'Trade count by size bucket',
  labelNames: ['bucket'],
  registers: [register],
});

// Inventory Metrics
const inventoryDevBps = new Gauge({
  name: 'dnmm_inventory_dev_bps',
  help: '10000 * |B - x*_inst| / x*_inst',
  registers: [register],
});

// Ladder Metrics
const ladderPoints = new Gauge({
  name: 'dnmm_ladder_fee_bps',
  help: 'Fee BPS for size ladder points',
  labelNames: ['size_multiplier'],
  registers: [register],
});

// Recenter Metrics
const recenterCommitsTotal = new Counter({
  name: 'dnmm_recenter_commits_total',
  help: 'Count of TargetBaseXstarUpdated events',
  registers: [register],
});

// Uptime Metrics
const twoSidedUptimePct = new Gauge({
  name: 'dnmm_two_sided_uptime_pct',
  help: 'Percentage of time with both sides > 0 size',
  registers: [register],
});

// Reject Rate Metrics (5-minute rolling window)
const rejectRate5m = new Gauge({
  name: 'dnmm_reject_rate_pct_5m',
  help: 'Rolling 5m reject rate percentage',
  registers: [register],
});

// Precompile Error Rate
const precompileErrorRate = new Gauge({
  name: 'dnmm_precompile_error_rate',
  help: 'HC precompile errors per 5m window',
  registers: [register],
});

// Restorative Trade Win Rate
const restorativeWinRatePct = new Gauge({
  name: 'dnmm_restorative_win_rate_pct',
  help: 'Percentage of frames where restorative side beats street',
  registers: [register],
});

// ═══════════════════════════════════════════════════════════════════════════
// Contract ABIs (minimal)
// ═══════════════════════════════════════════════════════════════════════════

const DNMM_POOL_ABI = [
  'function quoteSwapExactIn(uint256 amountIn, bool isBaseIn, uint8 mode, bytes calldata oracleData) external returns (tuple(uint256 amountOut, uint16 feeBps, bytes32 reason, bool aomqTriggered))',
  'function previewFees(uint256[] calldata sizes, bool isBaseIn, uint8 mode, bytes calldata oracleData) external view returns (uint256[] memory)',
  'function reserves() external view returns (uint128 baseReserves, uint128 quoteReserves)',
  'function inventoryConfig() external view returns (tuple(uint128 targetBaseXstar, uint16 floorBps, uint16 recenterThresholdPct, uint16 invTiltBpsPer1pct, uint16 invTiltMaxBps, uint16 tiltConfWeightBps, uint16 tiltSpreadWeightBps))',
  'function lastMid() external view returns (uint256)',
  'event SwapExecuted(address indexed user, uint256 amountIn, uint256 amountOut, bool isBaseIn, uint16 feeBps, bytes32 reason)',
  'event DivergenceHaircut(uint256 deltaBps, uint256 extraFeeBps)',
  'event DivergenceRejected(uint256 deltaBps)',
  'event AomqActivated(bytes32 trigger, bool isBaseIn, uint256 amountIn, uint256 quoteNotional, uint16 spreadBps)',
  'event TargetBaseXstarUpdated(uint128 oldTarget, uint128 newTarget, uint256 mid, uint64 timestamp)',
];

const PYTH_ABI = [
  'function getPriceUnsafe(bytes32 id) external view returns (tuple(int64 price, uint64 conf, int32 expo, uint256 publishTime))',
];

const HC_ADAPTER_ABI = [
  'function readMidAndAge() external view returns (uint256 mid, uint256 ageSec)',
  'function readBidAsk() external view returns (uint256 bid, uint256 ask, uint256 spreadBps)',
];

// ═══════════════════════════════════════════════════════════════════════════
// Metrics Collector
// ═══════════════════════════════════════════════════════════════════════════

class MetricsCollector {
  private provider: ethers.providers.JsonRpcProvider;
  private dnmPool: ethers.Contract;
  private pythOracle: ethers.Contract;
  private hcAdapter: ethers.Contract;

  // Rolling windows for rate calculations
  private rejectWindow: { timestamp: number; rejected: boolean }[] = [];
  private uptimeWindow: { timestamp: number; twoSided: boolean }[] = [];
  private restorativeWindow: { timestamp: number; won: boolean }[] = [];

  constructor() {
    this.provider = new ethers.providers.JsonRpcProvider(config.rpcUrl);
    this.dnmPool = new ethers.Contract(config.dnmPoolAddress, DNMM_POOL_ABI, this.provider);
    this.pythOracle = new ethers.Contract(config.pythOracleAddress, PYTH_ABI, this.provider);
    this.hcAdapter = new ethers.Contract(config.hcOracleAddress, HC_ADAPTER_ABI, this.provider);
  }

  async collect() {
    try {
      await Promise.all([
        this.collectOracleMetrics(),
        this.collectFeeMetrics(),
        this.collectInventoryMetrics(),
        this.collectLadderMetrics(),
        this.collectUptimeMetrics(),
        this.collectRateMetrics(),
      ]);
    } catch (error) {
      console.error('Metrics collection error:', error);
    }
  }

  private async collectOracleMetrics() {
    // Read HC mid + spread
    const [hcMid, _] = await this.hcAdapter.readMidAndAge();
    const [bid, ask, spreadBps] = await this.hcAdapter.readBidAsk();
    hcSpreadBps.set(Number(spreadBps.toString()));

    // Read Pyth mid + conf
    const hypePrice = await this.pythOracle.getPriceUnsafe(config.pythPriceIdHype);
    const usdcPrice = await this.pythOracle.getPriceUnsafe(config.pythPriceIdUsdc);

    const pythMid = this.scalePythPrice(hypePrice.price, hypePrice.expo) / this.scalePythPrice(usdcPrice.price, usdcPrice.expo);
    const pythConf = this.scalePythPrice(hypePrice.conf, hypePrice.expo);
    const confBps = (pythConf / pythMid) * 10000;
    pythConfBps.set(confBps);

    // Compute delta
    const hcMidScaled = Number(ethers.utils.formatUnits(hcMid, 18));
    const delta = Math.abs(hcMidScaled - pythMid) / pythMid;
    const deltaBpsValue = delta * 10000;
    deltaBps.set(deltaBpsValue);

    // Update decision labels based on divergence state
    if (deltaBpsValue <= 30) {
      decisionCounter.labels('accept').inc(0); // Touch label
    } else if (deltaBpsValue <= 50) {
      decisionCounter.labels('haircut').inc(0);
    } else if (deltaBpsValue <= 75) {
      decisionCounter.labels('aomq').inc(0);
    } else {
      decisionCounter.labels('reject').inc(0);
    }
  }

  private scalePythPrice(price: ethers.BigNumberish, expo: number): number {
    const priceBN = ethers.BigNumber.from(price);
    const exponent = Math.abs(expo);
    const divisor = Math.pow(10, exponent);
    return Number(priceBN.toString()) / divisor;
  }

  private async collectFeeMetrics() {
    // Sample small quote to get current fee (both sides)
    const sampleSize = ethers.utils.parseUnits('1000', 6); // 1000 USDC

    try {
      // Ask fee (base -> quote)
      const askQuote = await this.dnmPool.callStatic.quoteSwapExactIn(
        sampleSize,
        false, // quote-in
        0, // HyperCore mode
        '0x'
      );
      feeAskBps.set(Number(askQuote.feeBps.toString()));

      // Bid fee (quote -> base)
      const bidQuote = await this.dnmPool.callStatic.quoteSwapExactIn(
        sampleSize,
        true, // base-in
        0,
        '0x'
      );
      feeBidBps.set(Number(bidQuote.feeBps.toString()));
    } catch (error) {
      // Quote may fail in reject states - record as zero
      console.warn('Fee collection failed (likely reject state):', error);
      feeAskBps.set(0);
      feeBidBps.set(0);
    }
  }

  private async collectInventoryMetrics() {
    const [baseReserves, quoteReserves] = await this.dnmPool.reserves();
    const invConfig = await this.dnmPool.inventoryConfig();
    const mid = await this.dnmPool.lastMid();

    // Compute instantaneous x* = (Q + P * B) / (2P)
    const B = Number(ethers.utils.formatUnits(baseReserves, 18));
    const Q = Number(ethers.utils.formatUnits(quoteReserves, 6));
    const P = Number(ethers.utils.formatUnits(mid, 18));

    const xStarInst = (Q + P * B) / (2 * P);
    const deviation = Math.abs(B - xStarInst);
    const devBps = (deviation / xStarInst) * 10000;

    inventoryDevBps.set(devBps);
  }

  private async collectLadderMetrics() {
    const s0 = 5000; // 5000 USDC (from config)
    const sizes = [s0, 2 * s0, 5 * s0, 10 * s0].map((s) => ethers.utils.parseUnits(s.toString(), 6));

    try {
      const fees = await this.dnmPool.callStatic.previewFees(sizes, false, 0, '0x');

      const multipliers = ['1x', '2x', '5x', '10x'];
      for (let i = 0; i < fees.length; i++) {
        ladderPoints.labels(multipliers[i]).set(Number(fees[i].toString()));
      }
    } catch (error) {
      console.warn('Ladder collection failed:', error);
    }
  }

  private async collectUptimeMetrics() {
    // Sample both sides with small quotes
    const sampleSize = ethers.utils.parseUnits('100', 6);
    let askAlive = false;
    let bidAlive = false;

    try {
      const askQuote = await this.dnmPool.callStatic.quoteSwapExactIn(sampleSize, false, 0, '0x');
      askAlive = askQuote.amountOut.gt(0);
    } catch {}

    try {
      const bidQuote = await this.dnmPool.callStatic.quoteSwapExactIn(sampleSize, true, 0, '0x');
      bidAlive = bidQuote.amountOut.gt(0);
    } catch {}

    const twoSided = askAlive && bidAlive;

    // Update rolling window (keep last 5 minutes)
    const now = Date.now();
    this.uptimeWindow.push({ timestamp: now, twoSided });
    this.uptimeWindow = this.uptimeWindow.filter((e) => now - e.timestamp < 5 * 60 * 1000);

    // Compute percentage
    const twoSidedCount = this.uptimeWindow.filter((e) => e.twoSided).length;
    const uptimePct = this.uptimeWindow.length > 0 ? (twoSidedCount / this.uptimeWindow.length) * 100 : 0;
    twoSidedUptimePct.set(uptimePct);
  }

  private async collectRateMetrics() {
    // Reject rate computed from event logs (simplified: check if quote fails)
    const sampleSize = ethers.utils.parseUnits('1000', 6);
    let rejected = false;

    try {
      await this.dnmPool.callStatic.quoteSwapExactIn(sampleSize, false, 0, '0x');
    } catch (error) {
      rejected = true;
    }

    const now = Date.now();
    this.rejectWindow.push({ timestamp: now, rejected });
    this.rejectWindow = this.rejectWindow.filter((e) => now - e.timestamp < 5 * 60 * 1000);

    const rejectCount = this.rejectWindow.filter((e) => e.rejected).length;
    const rejectPct = this.rejectWindow.length > 0 ? (rejectCount / this.rejectWindow.length) * 100 : 0;
    rejectRate5m.set(rejectPct);
  }

  async listenToEvents() {
    // Subscribe to recenter events
    this.dnmPool.on('TargetBaseXstarUpdated', () => {
      recenterCommitsTotal.inc();
    });

    // Subscribe to reject events
    this.dnmPool.on('DivergenceRejected', () => {
      decisionCounter.labels('reject').inc();
    });

    // Subscribe to haircut events
    this.dnmPool.on('DivergenceHaircut', () => {
      decisionCounter.labels('haircut').inc();
    });

    // Subscribe to AOMQ events
    this.dnmPool.on('AomqActivated', () => {
      decisionCounter.labels('aomq').inc();
    });

    // Subscribe to swap events for size bucketing
    this.dnmPool.on('SwapExecuted', (user, amountIn, amountOut, isBaseIn, feeBps, reason) => {
      const notional = Number(ethers.utils.formatUnits(isBaseIn ? amountOut : amountIn, 6));
      const s0 = 5000;

      if (notional <= s0) {
        sizeBucketCounter.labels('<=S0').inc();
      } else if (notional <= 2 * s0) {
        sizeBucketCounter.labels('S0..2S0').inc();
      } else {
        sizeBucketCounter.labels('>2S0').inc();
      }

      // Track decision type
      if (reason === ethers.utils.formatBytes32String('HAIRCUT')) {
        decisionCounter.labels('haircut').inc();
      } else if (reason === ethers.utils.formatBytes32String('AOMQ')) {
        decisionCounter.labels('aomq').inc();
      } else {
        decisionCounter.labels('accept').inc();
      }
    });
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Prometheus HTTP Server
// ═══════════════════════════════════════════════════════════════════════════

import express from 'express';

const app = express();

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

async function main() {
  console.log('Starting DNMM L3 Metrics Exporter...');
  console.log('Pool:', config.dnmPoolAddress);
  console.log('Interval:', config.collectIntervalMs, 'ms');
  console.log('Prometheus port:', config.prometheusPort);

  const collector = new MetricsCollector();

  // Start event listeners
  await collector.listenToEvents();

  // Start periodic collection
  setInterval(async () => {
    await collector.collect();
  }, config.collectIntervalMs);

  // Start HTTP server
  app.listen(config.prometheusPort, () => {
    console.log(`Metrics server listening on :${config.prometheusPort}/metrics`);
  });
}

main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
