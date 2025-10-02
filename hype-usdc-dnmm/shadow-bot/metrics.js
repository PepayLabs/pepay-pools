import http from 'http';
import { Counter, Gauge, Histogram, Registry, collectDefaultMetrics } from 'prom-client';
const TWO_SIDED_WINDOW_MS = 15 * 60 * 1000;
class RollingUptime {
    windowMs;
    samples = [];
    constructor(windowMs) {
        this.windowMs = windowMs;
    }
    addSample(timestampMs, twoSided) {
        this.samples.push({ timestampMs, twoSided });
        this.evict(timestampMs);
    }
    getUptimePct(nowMs) {
        this.evict(nowMs);
        if (this.samples.length === 0)
            return 0;
        const twoSidedCount = this.samples.filter((sample) => sample.twoSided).length;
        return (twoSidedCount / this.samples.length) * 100;
    }
    evict(nowMs) {
        while (this.samples.length > 0 && nowMs - this.samples[0].timestampMs > this.windowMs) {
            this.samples.shift();
        }
    }
}
function withCommonLabels(config, labels) {
    return {
        pair: config.labels.pair,
        chain: config.labels.chain,
        ...(labels ?? {})
    };
}
export class MetricsManager {
    config;
    registry = new Registry();
    handles;
    uptimeTracker;
    server;
    constructor(config) {
        this.config = config;
        collectDefaultMetrics({ register: this.registry });
        this.handles = this.createMetrics();
        this.uptimeTracker = new RollingUptime(TWO_SIDED_WINDOW_MS);
    }
    getRegister() {
        return this.registry;
    }
    async startServer() {
        if (this.server)
            return;
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
                }
                catch (error) {
                    res.writeHead(500);
                    res.end(error.message);
                }
                return;
            }
            res.writeHead(404);
            res.end('Not found');
        });
        await new Promise((resolve, reject) => {
            if (!this.server)
                return resolve();
            this.server.listen(this.config.promPort, resolve);
            this.server.on('error', reject);
        });
    }
    async stopServer() {
        if (!this.server)
            return;
        await new Promise((resolve) => this.server?.close(() => resolve()));
        this.server = undefined;
    }
    recordPoolState(state) {
        this.handles.baseReserves.set(withCommonLabels(this.config), Number(state.baseReserves));
        this.handles.quoteReserves.set(withCommonLabels(this.config), Number(state.quoteReserves));
        this.handles.lastMid.set(withCommonLabels(this.config), Number(state.lastMidWad));
        if (state.snapshotAgeSec !== undefined) {
            this.handles.snapshotAge.set(withCommonLabels(this.config), state.snapshotAgeSec);
        }
    }
    recordRegime(flags) {
        this.handles.regimeBits.set(withCommonLabels(this.config), flags.bitmask);
    }
    recordOracle(snapshot) {
        if (snapshot.hc.status === 'ok' && snapshot.hc.spreadBps !== undefined) {
            this.handles.bboSpread.observe(withCommonLabels(this.config), snapshot.hc.spreadBps);
        }
        if (snapshot.pyth && snapshot.pyth.status === 'ok' && snapshot.pyth.confBps !== undefined) {
            this.handles.confBps.observe(withCommonLabels(this.config), snapshot.pyth.confBps);
        }
        if (snapshot.hc.status === 'ok' &&
            snapshot.pyth &&
            snapshot.pyth.status === 'ok' &&
            snapshot.hc.midWad &&
            snapshot.pyth.midWad &&
            snapshot.pyth.midWad !== 0n) {
            const diff = snapshot.hc.midWad > snapshot.pyth.midWad
                ? snapshot.hc.midWad - snapshot.pyth.midWad
                : snapshot.pyth.midWad - snapshot.hc.midWad;
            const deltaBps = Number((diff * 10000n) / snapshot.pyth.midWad);
            this.handles.deltaBps.observe(withCommonLabels(this.config), deltaBps);
        }
    }
    recordProbe(probe, rung, regimeLabel) {
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
    recordTwoSided(timestampMs, twoSided) {
        this.uptimeTracker.addSample(timestampMs, twoSided);
        const pct = this.uptimeTracker.getUptimePct(timestampMs);
        this.handles.twoSidedUptime.set(withCommonLabels(this.config), pct);
    }
    incrementPrecompileError() {
        this.handles.precompileErrors.inc(withCommonLabels(this.config));
    }
    incrementPreviewStale() {
        this.handles.previewStale.inc(withCommonLabels(this.config));
    }
    incrementAomqClamp() {
        this.handles.aomqClamps.inc(withCommonLabels(this.config));
    }
    incrementRecenterCommit() {
        this.handles.recenterCommits.inc(withCommonLabels(this.config));
    }
    recordQuoteResult(result) {
        this.handles.quotes.inc(withCommonLabels(this.config, { result }));
    }
    recordProviderSample(sample) {
        const resultLabel = sample.success ? 'success' : 'error';
        const labels = withCommonLabels(this.config, {
            method: sample.method,
            result: resultLabel
        });
        this.handles.providerCalls.inc(labels);
    }
    setLastRebalancePrice(midWad) {
        this.handles.lastRebalance.set(withCommonLabels(this.config), Number(midWad));
    }
    createMetrics() {
        const snapshotAge = new Gauge({
            name: 'dnmm_snapshot_age_sec',
            help: 'Age of preview snapshot used in last loop',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const regimeBits = new Gauge({
            name: 'dnmm_regime_bits',
            help: 'Bitmask of current regime (AOMQ=1, Fallback=2, NearFloor=4, SizeFee=8, InvTilt=16)',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const baseReserves = new Gauge({
            name: 'dnmm_pool_base_reserves',
            help: 'Base token reserves (raw units)',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const quoteReserves = new Gauge({
            name: 'dnmm_pool_quote_reserves',
            help: 'Quote token reserves (raw units)',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const lastMid = new Gauge({
            name: 'dnmm_last_mid_wad',
            help: 'Last mid used in WAD',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const lastRebalance = new Gauge({
            name: 'dnmm_last_rebalance_price_wad',
            help: 'Last rebalance price (WAD) if available',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const quoteLatency = new Histogram({
            name: 'dnmm_quote_latency_ms',
            help: 'Latency of preview quotes',
            buckets: this.config.histogramBuckets.quoteLatencyMs,
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const deltaBps = new Histogram({
            name: 'dnmm_delta_bps',
            help: 'HC vs Pyth delta in bps',
            buckets: this.config.histogramBuckets.deltaBps,
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const confBps = new Histogram({
            name: 'dnmm_conf_bps',
            help: 'Pyth confidence in bps of price',
            buckets: this.config.histogramBuckets.confBps,
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const bboSpread = new Histogram({
            name: 'dnmm_bbo_spread_bps',
            help: 'HC BBO spread bps',
            buckets: this.config.histogramBuckets.bboSpreadBps,
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const feeBps = new Histogram({
            name: 'dnmm_fee_bps',
            help: 'Fee bps for probe quotes',
            buckets: this.config.histogramBuckets.feeBps,
            registers: [this.registry],
            labelNames: ['pair', 'chain', 'side', 'rung', 'regime']
        });
        const totalBps = new Histogram({
            name: 'dnmm_total_bps',
            help: 'Total bps (fee + slippage vs chosen mid) for probe quotes',
            buckets: this.config.histogramBuckets.totalBps,
            registers: [this.registry],
            labelNames: ['pair', 'chain', 'side', 'rung', 'regime']
        });
        const providerCalls = new Counter({
            name: 'dnmm_provider_calls_total',
            help: 'JSON-RPC provider calls grouped by method/result',
            registers: [this.registry],
            labelNames: ['pair', 'chain', 'method', 'result']
        });
        const precompileErrors = new Counter({
            name: 'dnmm_precompile_errors_total',
            help: 'Count of HyperCore precompile read failures',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const previewStale = new Counter({
            name: 'dnmm_preview_stale_reverts_total',
            help: 'Preview stale reverts due to config',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const aomqClamps = new Counter({
            name: 'dnmm_aomq_clamps_total',
            help: 'Count of AOMQ clamp signals over lifetime',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const recenterCommits = new Counter({
            name: 'dnmm_recenter_commits_total',
            help: 'Count of TargetBaseXstarUpdated events seen',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
        });
        const quotes = new Counter({
            name: 'dnmm_quotes_total',
            help: 'Quotes issued by the bot',
            registers: [this.registry],
            labelNames: ['pair', 'chain', 'result']
        });
        const twoSidedUptime = new Gauge({
            name: 'dnmm_two_sided_uptime_pct',
            help: 'Rolling 15m fraction of time both sides had >0 size available',
            registers: [this.registry],
            labelNames: ['pair', 'chain']
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
export function createMetricsManager(config) {
    return new MetricsManager(config);
}
