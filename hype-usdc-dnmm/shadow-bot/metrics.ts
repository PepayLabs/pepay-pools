import http from 'http';
import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from 'prom-client';
import {
  BenchmarkQuoteSample,
  BenchmarkTradeResult,
  MultiRunRuntimeConfig,
  OracleSnapshot,
  PrometheusLabelSet
} from './types.js';

const QUOTE_LATENCY_BUCKETS = [1, 5, 10, 20, 50, 100, 200, 500, 1_000];
const TRADE_SIZE_BUCKETS = [0.001, 0.01, 0.1, 1, 5, 10, 25, 50, 100, 250, 500];
const SLIPPAGE_BUCKETS = [0.1, 0.5, 1, 2, 5, 10, 25, 50, 75, 100];

interface MetricsContext {
  recordOracle(snapshot: OracleSnapshot): void;
  recordQuote(sample: BenchmarkQuoteSample): void;
  recordTrade(result: BenchmarkTradeResult): void;
  recordReject(): void;
  recordTwoSided(timestampMs: number, twoSided: boolean): void;
}

export class MetricsManager {
  private readonly registry = new Registry();
  private readonly server?: http.Server;
  private readonly contexts = new Map<string, MetricsContextImpl>();
  private readonly config: MultiRunRuntimeConfig;

  private readonly gauges = createGauges(this.registry);
  private readonly counters = createCounters(this.registry);
  private readonly histograms = createHistograms(this.registry);

  constructor(config: MultiRunRuntimeConfig) {
    this.config = config;
    collectDefaultMetrics({ register: this.registry });
    this.server = http.createServer(async (_req, res) => {
      res.setHeader('Content-Type', this.registry.contentType);
      res.end(await this.registry.metrics());
    });
  }

  async start(): Promise<void> {
    if (!this.server || this.config.promPort <= 0) return;
    await new Promise<void>((resolve) => this.server!.listen(this.config.promPort, resolve));
  }

  async stop(): Promise<void> {
    if (!this.server || this.config.promPort <= 0) return;
    await new Promise<void>((resolve, reject) => {
      this.server!.close((error) => {
        if (error) reject(error);
        else resolve();
      });
    });
  }

  context(settingId: string, benchmark: string): MetricsContext {
    const key = `${settingId}::${benchmark}`;
    let ctx = this.contexts.get(key);
    if (!ctx) {
      const labels: PrometheusLabelSet = {
        run_id: this.config.runId,
        setting_id: settingId,
        benchmark: benchmark as any,
        pair: this.config.pairLabels.pair
      };
      ctx = new MetricsContextImpl(labels, this.gauges, this.counters, this.histograms);
      this.contexts.set(key, ctx);
    }
    return ctx;
  }

  recordRecenter(settingId: string, benchmark: string): void {
    const labels: PrometheusLabelSet = {
      run_id: this.config.runId,
      setting_id: settingId,
      benchmark: benchmark as any,
      pair: this.config.pairLabels.pair
    };
    this.counters.recenter.inc(labels);
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

  recordOracle(snapshot: OracleSnapshot): void {
    if (snapshot.hc.midWad !== undefined) {
      this.gauges.mid.set(this.labels, Number(snapshot.hc.midWad));
    }
    if (snapshot.hc.spreadBps !== undefined) {
      this.gauges.spread.set(this.labels, snapshot.hc.spreadBps);
    }
    if (snapshot.hc.ageSec !== undefined) {
      this.gauges.snapshotAge.set(this.labels, snapshot.hc.ageSec);
    }
    if (snapshot.pyth?.confBps !== undefined) {
      this.gauges.conf.set(this.labels, snapshot.pyth.confBps);
    }
  }

  recordQuote(sample: BenchmarkQuoteSample): void {
    const quoteLabels = { ...this.labels, side: sample.side } as const;
    this.counters.quotes.inc(quoteLabels);
    this.histograms.quoteLatency.observe(quoteLabels, 10);
    this.gauges.mid.set(this.labels, Number(sample.mid));
    this.gauges.spread.set(this.labels, sample.spreadBps);
    if (sample.confBps !== undefined) {
      this.gauges.conf.set(this.labels, sample.confBps);
    }
  }

  recordTrade(result: BenchmarkTradeResult): void {
    this.counters.trades.inc(this.labels);
    this.histograms.tradeSize.observe(this.labels, Number(result.amountIn));
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
  }

  recordReject(): void {
    this.counters.rejects.inc(this.labels);
  }

  recordTwoSided(timestampMs: number, twoSided: boolean): void {
    this.uptime.addSample(timestampMs, twoSided);
    this.gauges.uptime.set(this.labels, this.uptime.getUptimePct(timestampMs));
  }
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
  const snapshotAge = new Gauge({
    name: 'shadow_snapshot_age_sec',
    help: 'Age of HyperCore snapshot in seconds',
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
  return { mid, spread, conf, snapshotAge, uptime, pnlTotal, pnlRate } as const;
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

export function createMetricsManager(config: MultiRunRuntimeConfig): MetricsManager {
  return new MetricsManager(config);
}
