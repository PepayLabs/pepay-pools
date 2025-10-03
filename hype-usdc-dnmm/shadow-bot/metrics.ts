import http from 'http';
import {
  Counter,
  Gauge,
  Histogram,
  Registry,
  collectDefaultMetrics
} from 'prom-client';
import {
  OracleSnapshot,
  PoolState,
  ProbeQuote,
  ProviderHealthSample,
  RegimeFlags,
  RollingUptimeTracker,
  ShadowBotConfig
} from './types.js';

const TWO_SIDED_WINDOW_MS = 15 * 60 * 1000;

class RollingUptime implements RollingUptimeTracker {
  private readonly samples: { timestampMs: number; twoSided: boolean }[] = [];

  constructor(private readonly windowMs: number) {}

  addSample(timestampMs: number, twoSided: boolean): void {
    this.samples.push({ timestampMs, twoSided });
    this.evict(timestampMs);
  }

  getUptimePct(nowMs: number): number {
    this.evict(nowMs);
    if (this.samples.length === 0) return 0;
    const twoSidedCount = this.samples.filter((sample) => sample.twoSided).length;
    return (twoSidedCount / this.samples.length) * 100;
  }

  private evict(nowMs: number): void {
    while (this.samples.length > 0 && nowMs - this.samples[0].timestampMs > this.windowMs) {
      this.samples.shift();
    }
  }
}

interface MetricHandles {
  snapshotAge: Gauge;
  regimeBits: Gauge;
  baseReserves: Gauge;
  quoteReserves: Gauge;
  lastMid: Gauge;
  lastRebalance: Gauge;
  quoteLatency: Histogram;
  deltaBps: Histogram;
  confBps: Histogram;
  bboSpread: Histogram;
  feeBps: Histogram;
  totalBps: Histogram;
  providerCalls: Counter;
  precompileErrors: Counter;
  previewStale: Counter;
  aomqClamps: Counter;
  recenterCommits: Counter;
  quotes: Counter;
  twoSidedUptime: Gauge;
}

function withCommonLabels<T extends Record<string, string>>(config: ShadowBotConfig, labels?: T): T & {
  pair: string;
  chain: string;
  mode: string;
} {
  return {
    pair: config.labels.pair,
    chain: config.labels.chain,
    mode: config.mode,
    ...(labels ?? ({} as T))
  };
}

export class MetricsManager {
  private readonly registry = new Registry();
  private readonly handles: MetricHandles;
  private readonly uptimeTracker: RollingUptime;
  private server?: http.Server;

  constructor(private readonly config: ShadowBotConfig) {
    collectDefaultMetrics({ register: this.registry });

    this.handles = this.createMetrics();
    this.uptimeTracker = new RollingUptime(TWO_SIDED_WINDOW_MS);
  }

  getRegister(): Registry {
    return this.registry;
  }

  async startServer(): Promise<void> {
    if (this.server) return;
    this.server = http.createServer(async (req, res) => {
      if (!req.url) {
        res.writeHead(400);
        res.end('Missing url');
        return;
      }
      if (req.url === '/metrics') {
        try {
          res.setHeader('Content-Type', this.registry.contentType);
          res.end(await this.registry.metrics());
        } catch (error) {
          res.writeHead(500);
          res.end((error as Error).message);
        }
        return;
      }
      res.writeHead(404);
      res.end('Not found');
    });

    await new Promise<void>((resolve, reject) => {
      if (!this.server) return resolve();
      this.server.listen(this.config.promPort, resolve);
      this.server.on('error', reject);
    });
  }

  async stopServer(): Promise<void> {
    if (!this.server) return;
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
    this.server = undefined;
  }

  recordPoolState(state: PoolState): void {
    this.handles.baseReserves.set(withCommonLabels(this.config), Number(state.baseReserves));
    this.handles.quoteReserves.set(withCommonLabels(this.config), Number(state.quoteReserves));
    this.handles.lastMid.set(withCommonLabels(this.config), Number(state.lastMidWad));
    if (state.snapshotAgeSec !== undefined) {
      this.handles.snapshotAge.set(withCommonLabels(this.config), state.snapshotAgeSec);
    }
  }

  recordRegime(flags: RegimeFlags): void {
    this.handles.regimeBits.set(withCommonLabels(this.config), flags.bitmask);
  }

  recordOracle(snapshot: OracleSnapshot): void {
    if (snapshot.hc.status === 'ok' && snapshot.hc.spreadBps !== undefined) {
      this.handles.bboSpread.observe(withCommonLabels(this.config), snapshot.hc.spreadBps);
    }
    if (snapshot.pyth && snapshot.pyth.status === 'ok' && snapshot.pyth.confBps !== undefined) {
      this.handles.confBps.observe(withCommonLabels(this.config), snapshot.pyth.confBps);
    }
    if (
      snapshot.hc.status === 'ok' &&
      snapshot.pyth &&
      snapshot.pyth.status === 'ok' &&
      snapshot.hc.midWad &&
      snapshot.pyth.midWad &&
      snapshot.pyth.midWad !== 0n
    ) {
      const diff = snapshot.hc.midWad > snapshot.pyth.midWad
        ? snapshot.hc.midWad - snapshot.pyth.midWad
        : snapshot.pyth.midWad - snapshot.hc.midWad;
      const deltaBps = Number((diff * 10_000n) / snapshot.pyth.midWad);
      this.handles.deltaBps.observe(withCommonLabels(this.config), deltaBps);
    }
  }

  recordProbe(probe: ProbeQuote, rung: number, regimeLabel: string): void {
    const labels = withCommonLabels(this.config, {
      side: probe.side,
      rung: String(rung),
      regime: regimeLabel
    });
    this.handles.quoteLatency.observe(withCommonLabels(this.config), probe.latencyMs);
    if (probe.success) {
      this.handles.feeBps.observe(labels, probe.feeBps);
      this.handles.totalBps.observe(labels, probe.totalBps);
    }
  }

  recordTwoSided(timestampMs: number, twoSided: boolean): void {
    this.uptimeTracker.addSample(timestampMs, twoSided);
    const pct = this.uptimeTracker.getUptimePct(timestampMs);
    this.handles.twoSidedUptime.set(withCommonLabels(this.config), pct);
  }

  incrementPrecompileError(): void {
    this.handles.precompileErrors.inc(withCommonLabels(this.config));
  }

  incrementPreviewStale(): void {
    this.handles.previewStale.inc(withCommonLabels(this.config));
  }

  incrementAomqClamp(): void {
    this.handles.aomqClamps.inc(withCommonLabels(this.config));
  }

  incrementRecenterCommit(): void {
    this.handles.recenterCommits.inc(withCommonLabels(this.config));
  }

  recordQuoteResult(result: 'ok' | 'error' | 'fallback'): void {
    this.handles.quotes.inc(withCommonLabels(this.config, { result }));
  }

  recordProviderSample(sample: ProviderHealthSample): void {
    const resultLabel = sample.success ? 'success' : 'error';
    const labels = withCommonLabels(this.config, {
      method: sample.method,
      result: resultLabel
    });
    this.handles.providerCalls.inc(labels);
  }

  setLastRebalancePrice(midWad: bigint): void {
    this.handles.lastRebalance.set(withCommonLabels(this.config), Number(midWad));
  }

  private createMetrics(): MetricHandles {
    const snapshotAge = new Gauge({
      name: 'dnmm_snapshot_age_sec',
      help: 'Age of preview snapshot used in last loop',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const regimeBits = new Gauge({
      name: 'dnmm_regime_bits',
      help: 'Bitmask of current regime (AOMQ=1, Fallback=2, NearFloor=4, SizeFee=8, InvTilt=16)',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const baseReserves = new Gauge({
      name: 'dnmm_pool_base_reserves',
      help: 'Base token reserves (raw units)',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const quoteReserves = new Gauge({
      name: 'dnmm_pool_quote_reserves',
      help: 'Quote token reserves (raw units)',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const lastMid = new Gauge({
      name: 'dnmm_last_mid_wad',
      help: 'Last mid used in WAD',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const lastRebalance = new Gauge({
      name: 'dnmm_last_rebalance_price_wad',
      help: 'Last rebalance price (WAD) if available',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const quoteLatency = new Histogram({
      name: 'dnmm_quote_latency_ms',
      help: 'Latency of preview quotes',
      buckets: this.config.histogramBuckets.quoteLatencyMs,
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const deltaBps = new Histogram({
      name: 'dnmm_delta_bps',
      help: 'HC vs Pyth delta in bps',
      buckets: this.config.histogramBuckets.deltaBps,
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const confBps = new Histogram({
      name: 'dnmm_conf_bps',
      help: 'Pyth confidence in bps of price',
      buckets: this.config.histogramBuckets.confBps,
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const bboSpread = new Histogram({
      name: 'dnmm_bbo_spread_bps',
      help: 'HC BBO spread bps',
      buckets: this.config.histogramBuckets.bboSpreadBps,
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const feeBps = new Histogram({
      name: 'dnmm_fee_bps',
      help: 'Fee bps for probe quotes',
      buckets: this.config.histogramBuckets.feeBps,
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode', 'side', 'rung', 'regime']
    });
    const totalBps = new Histogram({
      name: 'dnmm_total_bps',
      help: 'Total bps (fee + slippage vs chosen mid) for probe quotes',
      buckets: this.config.histogramBuckets.totalBps,
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode', 'side', 'rung', 'regime']
    });
    const providerCalls = new Counter({
      name: 'dnmm_provider_calls_total',
      help: 'JSON-RPC provider calls grouped by method/result',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode', 'method', 'result']
    });
    const precompileErrors = new Counter({
      name: 'dnmm_precompile_errors_total',
      help: 'Count of HyperCore precompile read failures',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const previewStale = new Counter({
      name: 'dnmm_preview_stale_reverts_total',
      help: 'Preview stale reverts due to config',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const aomqClamps = new Counter({
      name: 'dnmm_aomq_clamps_total',
      help: 'Count of AOMQ clamp signals over lifetime',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const recenterCommits = new Counter({
      name: 'dnmm_recenter_commits_total',
      help: 'Count of TargetBaseXstarUpdated events seen',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });
    const quotes = new Counter({
      name: 'dnmm_quotes_total',
      help: 'Quotes issued by the bot',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode', 'result']
    });
    const twoSidedUptime = new Gauge({
      name: 'dnmm_two_sided_uptime_pct',
      help: 'Rolling 15m fraction of time both sides had >0 size available',
      registers: [this.registry],
      labelNames: ['pair', 'chain', 'mode']
    });

    return {
      snapshotAge,
      regimeBits,
      baseReserves,
      quoteReserves,
      lastMid,
      lastRebalance,
      quoteLatency,
      deltaBps,
      confBps,
      bboSpread,
      feeBps,
      totalBps,
      providerCalls,
      precompileErrors,
      previewStale,
      aomqClamps,
      recenterCommits,
      quotes,
      twoSidedUptime
    };
  }
}

export function createMetricsManager(config: ShadowBotConfig): MetricsManager {
  return new MetricsManager(config);
}

export type { RollingUptime };
