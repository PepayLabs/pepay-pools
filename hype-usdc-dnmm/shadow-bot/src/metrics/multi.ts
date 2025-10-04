import http from 'http';
import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from 'prom-client';
import {
  BenchmarkId,
  BenchmarkQuoteSample,
  BenchmarkTradeResult,
  MultiRunRuntimeConfig,
  PrometheusLabelSet,
  ScoreboardRow,
  OracleSnapshot,
  PoolState
} from '../types.js';

const QUOTE_LATENCY_BUCKETS = [1, 5, 10, 20, 50, 100, 200, 500, 1_000];
const TRADE_SIZE_BUCKETS = [0.001, 0.01, 0.1, 1, 5, 10, 25, 50, 100, 250, 500];
const SLIPPAGE_BUCKETS = [0.1, 0.5, 1, 2, 5, 10, 25, 50, 75, 100];
const WAD = 10n ** 18n;

interface MetricsContext {
  recordOracle(sample: { mid: bigint; spreadBps?: number; confBps?: number; sigmaBps?: number }): void;
  recordQuote(sample: BenchmarkQuoteSample): void;
  recordTrade(result: BenchmarkTradeResult): void;
  recordReject(): void;
  recordTwoSided(timestampMs: number, twoSided: boolean): void;
}

class RollingUptime {
  private readonly samples: { timestampMs: number; twoSided: boolean }[] = [];

  constructor(private readonly windowMs: number) {}

  addSample(timestampMs: number, twoSided: boolean): void {
    this.samples.push({ timestampMs, twoSided });
    this.evict(timestampMs);
  }

  getUptimePct(nowMs: number): number {
    this.evict(nowMs);
    if (this.samples.length === 0) return 0;
    const satisfied = this.samples.filter((sample) => sample.twoSided).length;
    return (satisfied / this.samples.length) * 100;
  }

  private evict(nowMs: number): void {
    while (this.samples.length > 0 && nowMs - this.samples[0].timestampMs > this.windowMs) {
      this.samples.shift();
    }
  }
}

export class MultiMetricsManager {
  private readonly registry = new Registry();
  private readonly contexts = new Map<string, MetricsContextImpl>();
  private readonly gauges = createGauges(this.registry);
  private readonly counters = createCounters(this.registry);
  private readonly histograms = createHistograms(this.registry);
  private readonly dnmmGauges: ReturnType<typeof createDnmmGauges> | undefined;
  private readonly server?: http.Server;

  constructor(private readonly config: MultiRunRuntimeConfig) {
    collectDefaultMetrics({ register: this.registry });
    this.server = http.createServer(async (_req, res) => {
      res.setHeader('Content-Type', this.registry.contentType);
      res.end(await this.registry.metrics());
    });
    this.dnmmGauges = this.config.runtime.mode === 'mock' ? undefined : createDnmmGauges(this.registry);
  }

  async start(): Promise<void> {
    if (!this.server || this.config.promPort <= 0) return;
    await new Promise<void>((resolve) => this.server!.listen(this.config.promPort, resolve));
  }

  async stop(): Promise<void> {
    if (!this.server || this.config.promPort <= 0) return;
    await new Promise<void>((resolve, reject) => {
      this.server!.close((error) => (error ? reject(error) : resolve()));
    });
  }

  context(settingId: string, benchmark: string): MetricsContext {
    const key = `${settingId}::${benchmark}`;
    let ctx = this.contexts.get(key);
    if (!ctx) {
      const labels = this.buildLabels(settingId, benchmark);
      ctx = new MetricsContextImpl(labels, this.gauges, this.counters, this.histograms);
      this.contexts.set(key, ctx);
    }
    return ctx;
  }

  recordRecenter(settingId: string, benchmark: string): void {
    const labels = this.buildLabels(settingId, benchmark);
    this.counters.recenter.inc(labels);
  }

  recordScoreboard(rows: readonly ScoreboardRow[]): void {
    for (const row of rows) {
      const labels = this.buildLabels(row.settingId, row.benchmark);
      this.gauges.routerWin.set(labels, row.routerWinRatePct);
      this.gauges.pnlPerRisk.set(labels, row.pnlPerRisk);
      this.gauges.avgSlippage.set(labels, row.avgSlippageBps);
      this.gauges.effectiveFee.set(labels, row.avgFeeAfterRebateBps);
      this.gauges.lvrCapture.set(labels, row.lvrCaptureBps);
      if (row.priceImprovementVsCpmmBps !== undefined) {
        this.gauges.priceImprovement.set(labels, row.priceImprovementVsCpmmBps);
      }
      this.gauges.previewStaleness.set(labels, row.previewStalenessRatioPct);
      this.gauges.timeoutRate.set(labels, row.timeoutExpiryRatePct);
    }
  }

  recordDnmmSnapshot(settingId: string, snapshot: {
    oracle: OracleSnapshot;
    poolState: PoolState;
  }): void {
    if (!this.dnmmGauges) return;
    const labels = this.buildLabels(settingId, 'dnmm');
    const mid = snapshot.oracle.hc.midWad ? wadToFloat(snapshot.oracle.hc.midWad) : undefined;
    if (mid !== undefined) {
      this.dnmmGauges.mid.set(labels, mid);
    }
    if (snapshot.oracle.hc.spreadBps !== undefined) {
      this.dnmmGauges.spread.set(labels, snapshot.oracle.hc.spreadBps);
    }
    if (snapshot.oracle.pyth?.confBps !== undefined) {
      this.dnmmGauges.conf.set(labels, snapshot.oracle.pyth.confBps);
    }
    if (snapshot.poolState.snapshotAgeSec !== undefined) {
      this.dnmmGauges.snapshotAge.set(labels, snapshot.poolState.snapshotAgeSec);
    }
    if (snapshot.poolState.baseReserves !== undefined) {
      this.dnmmGauges.baseReserves.set(labels, bigintToFloat(snapshot.poolState.baseReserves, this.config.baseConfig.baseDecimals));
    }
    if (snapshot.poolState.quoteReserves !== undefined) {
      this.dnmmGauges.quoteReserves.set(labels, bigintToFloat(snapshot.poolState.quoteReserves, this.config.baseConfig.quoteDecimals));
    }
    if (snapshot.poolState.sigmaBps !== undefined) {
      this.dnmmGauges.sigma.set(labels, snapshot.poolState.sigmaBps);
    }
  }

  private buildLabels(settingId: string, benchmark: string): PrometheusLabelSet {
    return {
      run_id: this.config.runId,
      setting_id: settingId,
      benchmark: benchmark as BenchmarkId,
      pair: this.config.pairLabels.pair
    };
  }
}

class MetricsContextImpl implements MetricsContext {
  private readonly uptime = new RollingUptime(5 * 60 * 1_000);
  private lastPnl = 0;
  private lastTimestamp = Date.now();

  constructor(
    private readonly labels: PrometheusLabelSet,
    private readonly gauges: ReturnType<typeof createGauges>,
    private readonly counters: ReturnType<typeof createCounters>,
    private readonly histograms: ReturnType<typeof createHistograms>
  ) {}

  recordOracle(sample: { mid: bigint; spreadBps?: number; confBps?: number; sigmaBps?: number }): void {
    this.gauges.mid.set(this.labels, wadToFloat(sample.mid));
    if (sample.spreadBps !== undefined) {
      this.gauges.spread.set(this.labels, sample.spreadBps);
    }
    if (sample.confBps !== undefined) {
      this.gauges.conf.set(this.labels, sample.confBps);
    }
    if (sample.sigmaBps !== undefined) {
      this.gauges.sigma.set(this.labels, sample.sigmaBps);
    }
  }

  recordQuote(sample: BenchmarkQuoteSample): void {
    const quoteLabels = { ...this.labels, side: sample.side } as const;
    this.counters.quotes.inc(quoteLabels);
    if (sample.latencyMs !== undefined) {
      this.histograms.quoteLatency.observe(quoteLabels, sample.latencyMs);
    }
    this.gauges.mid.set(this.labels, wadToFloat(sample.mid));
    this.gauges.spread.set(this.labels, sample.spreadBps);
    if (sample.confBps !== undefined) {
      this.gauges.conf.set(this.labels, sample.confBps);
    }
  }

  recordTrade(result: BenchmarkTradeResult): void {
    this.counters.trades.inc(this.labels);
    const baseSizeWad =
      result.intentBaseSizeWad ??
      result.executedBaseSizeWad ??
      (result.intent.side === 'base_in'
        ? result.appliedAmountIn ?? result.amountIn
        : result.amountOut);
    if (baseSizeWad !== undefined) {
      this.histograms.tradeSize.observe(this.labels, wadToFloat(baseSizeWad));
    }
    this.histograms.tradeSlippage.observe(this.labels, result.slippageBpsVsMid);
    if (result.aomqClamped) {
      this.counters.aomq.inc(this.labels);
    }
    const now = Date.now();
    this.lastPnl += result.pnlQuote;
    this.gauges.pnlTotal.set(this.labels, this.lastPnl);
    const elapsedMinutes = (now - this.lastTimestamp) / 60_000;
    if (elapsedMinutes > 0) {
      this.gauges.pnlRate.set(this.labels, this.lastPnl / elapsedMinutes);
    }
    this.lastTimestamp = now;

    const latencyLabels = { ...this.labels, side: result.intent.side } as const;
    if (Number.isFinite(result.latencyMs)) {
      this.histograms.quoteLatency.observe(latencyLabels, result.latencyMs);
    }
  }

  recordReject(): void {
    this.counters.rejects.inc(this.labels);
  }

  recordTwoSided(timestampMs: number, twoSided: boolean): void {
    this.uptime.addSample(timestampMs, twoSided);
    this.gauges.uptime.set(this.labels, this.uptime.getUptimePct(timestampMs));
  }
}

function createGauges(register: Registry) {
  const mid = new Gauge({
    name: 'shadow_mid',
    help: 'Mid price used for last operation (scaled)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const spread = new Gauge({
    name: 'shadow_spread_bps',
    help: 'Spread applied in basis points',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const conf = new Gauge({
    name: 'shadow_conf_bps',
    help: 'Confidence interval basis points',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const sigma = new Gauge({
    name: 'shadow_sigma_bps',
    help: 'Implied sigma (bps)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const uptime = new Gauge({
    name: 'shadow_uptime_two_sided_pct',
    help: 'Two-sided uptime percentage',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const pnlTotal = new Gauge({
    name: 'shadow_pnl_quote_cum',
    help: 'Cumulative quote PnL',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const pnlRate = new Gauge({
    name: 'shadow_pnl_quote_rate',
    help: 'PnL rate per minute',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const routerWin = new Gauge({
    name: 'shadow_router_win_rate_pct',
    help: 'Router win rate percentage from scoreboard aggregation',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const pnlPerRisk = new Gauge({
    name: 'shadow_pnl_per_risk',
    help: 'PnL per unit of risk (scoreboard aggregate)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const priceImprovement = new Gauge({
    name: 'shadow_price_improvement_vs_cpmm_bps',
    help: 'Average price improvement versus CPMM comparator (bps)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const previewStaleness = new Gauge({
    name: 'shadow_preview_staleness_ratio_pct',
    help: 'Preview staleness ratio percentage',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const timeoutRate = new Gauge({
    name: 'shadow_timeout_expiry_rate_pct',
    help: 'Timeout expiry rate percentage',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const effectiveFee = new Gauge({
    name: 'shadow_effective_fee_after_rebate_bps',
    help: 'Effective fee after rebates (bps)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const avgSlippage = new Gauge({
    name: 'shadow_avg_slippage_bps',
    help: 'Average slippage in bps',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const lvrCapture = new Gauge({
    name: 'shadow_lvr_capture_bps',
    help: 'Average LVR capture in basis points',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  return {
    mid,
    spread,
    conf,
    sigma,
    uptime,
    pnlTotal,
    pnlRate,
    routerWin,
    pnlPerRisk,
    priceImprovement,
    previewStaleness,
    timeoutRate,
    effectiveFee,
    avgSlippage,
    lvrCapture
  } as const;
}

function createCounters(register: Registry) {
  const quotes = new Counter({
    name: 'shadow_quotes_total',
    help: 'Total quotes sampled',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair', 'side'],
    registers: [register]
  });
  const trades = new Counter({
    name: 'shadow_trades_total',
    help: 'Total executed trades',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const rejects = new Counter({
    name: 'shadow_rejects_total',
    help: 'Rejected trade intents',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const aomq = new Counter({
    name: 'shadow_aomq_clamps_total',
    help: 'Count of AOMQ clamps observed',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const recenter = new Counter({
    name: 'shadow_recenter_commits_total',
    help: 'Recenter commit events',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  return { quotes, trades, rejects, aomq, recenter } as const;
}

function createHistograms(register: Registry) {
  const tradeSize = new Histogram({
    name: 'shadow_trade_size_base_wad',
    help: 'Trade size in base asset (wad)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    buckets: TRADE_SIZE_BUCKETS,
    registers: [register]
  });
  const tradeSlippage = new Histogram({
    name: 'shadow_trade_slippage_bps',
    help: 'Observed slippage in bps',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    buckets: SLIPPAGE_BUCKETS,
    registers: [register]
  });
  const quoteLatency = new Histogram({
    name: 'shadow_quote_latency_ms',
    help: 'Quote latency in milliseconds',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair', 'side'],
    buckets: QUOTE_LATENCY_BUCKETS,
    registers: [register]
  });
  return { tradeSize, tradeSlippage, quoteLatency } as const;
}

function createDnmmGauges(register: Registry) {
  const mid = new Gauge({
    name: 'dnmm_last_mid_wad',
    help: 'Live DNMM mid price (wad -> decimal)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const spread = new Gauge({
    name: 'dnmm_hc_spread_bps',
    help: 'HyperCore spread in bps',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const conf = new Gauge({
    name: 'dnmm_pyth_conf_bps',
    help: 'Pyth confidence interval (bps)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const snapshotAge = new Gauge({
    name: 'dnmm_snapshot_age_sec',
    help: 'Preview snapshot age in seconds',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const baseReserves = new Gauge({
    name: 'dnmm_pool_base_reserves',
    help: 'Pool base reserves (scaled)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const quoteReserves = new Gauge({
    name: 'dnmm_pool_quote_reserves',
    help: 'Pool quote reserves (scaled)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  const sigma = new Gauge({
    name: 'dnmm_sigma_bps',
    help: 'Observed sigma (bps)',
    labelNames: ['run_id', 'setting_id', 'benchmark', 'pair'],
    registers: [register]
  });
  return { mid, spread, conf, snapshotAge, baseReserves, quoteReserves, sigma } as const;
}

function wadToFloat(value: bigint): number {
  if (value === 0n) return 0;
  return Number(value) / Number(WAD);
}

function bigintToFloat(value: bigint, decimals: number): number {
  if (decimals === 0) {
    return Number(value);
  }
  const scale = 10n ** BigInt(decimals);
  return Number(value) / Number(scale);
}
