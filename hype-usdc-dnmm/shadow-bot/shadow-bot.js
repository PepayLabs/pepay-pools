import 'dotenv/config';
import { Contract } from 'ethers';
import { loadConfig } from './config.js';
import { IDNM_POOL_ABI } from './abis.js';
import { createProviderManager } from './providers.js';
import { PoolClient } from './poolClient.js';
import { OracleReader } from './oracleReader.js';
import { createMetricsManager } from './metrics.js';
import { buildCsvRows, createCsvWriter } from './csvWriter.js';
import { runSyntheticProbes } from './probes.js';
import { REGIME_BIT_VALUES } from './types.js';
const LEVEL_WEIGHT = {
    debug: 10,
    info: 20,
    error: 30
};
function createLogger(level) {
    function shouldLog(target) {
        return LEVEL_WEIGHT[target] >= LEVEL_WEIGHT[level];
    }
    function emit(target, message, meta) {
        if (!shouldLog(target))
            return;
        const payload = {
            ts: new Date().toISOString(),
            level: target,
            msg: message,
            ...(meta ?? {})
        };
        const line = JSON.stringify(payload);
        if (target === 'error') {
            console.error(line);
        }
        else {
            console.log(line);
        }
    }
    return {
        level,
        info: (message, meta) => emit('info', message, meta),
        debug: (message, meta) => emit('debug', message, meta),
        error: (message, meta) => emit('error', message, meta)
    };
}
function aggregateRegimeFlags(probes) {
    const flags = new Set();
    for (const probe of probes) {
        probe.riskBits.forEach((flag) => flags.add(flag));
    }
    let bitmask = 0;
    for (const flag of flags) {
        bitmask |= REGIME_BIT_VALUES[flag];
    }
    return {
        bitmask,
        asArray: Array.from(flags)
    };
}
function probeRegimeLabel(probe) {
    return probe.riskBits.length === 0 ? 'calm' : probe.riskBits.join('|');
}
function mergeQuoteResult(probe) {
    if (!probe.success)
        return 'error';
    if (probe.usedFallback || probe.riskBits.includes('Fallback'))
        return 'fallback';
    return 'ok';
}
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
function detectTwoSided(probes) {
    const baseIn = probes.some((probe) => probe.side === 'base_in' && probe.success);
    const quoteIn = probes.some((probe) => probe.side === 'quote_in' && probe.success);
    return baseIn && quoteIn;
}
async function setupEventSubscriptions(config, providers, metrics, logger) {
    if (!providers.ws) {
        logger.info('ws.provider.unavailable', { note: 'Event subscriptions disabled' });
        return undefined;
    }
    const wsContract = new Contract(config.poolAddress, IDNM_POOL_ABI, providers.ws);
    const recenterHandler = (_oldTarget, newTarget, mid) => {
        metrics.incrementRecenterCommit();
        metrics.setLastRebalancePrice(mid);
        logger.info('event.recenter', {
            newTarget: newTarget.toString(),
            midWad: mid.toString()
        });
    };
    const aomqHandler = (trigger, isBaseIn, amountIn, quoteNotional, spreadBps) => {
        metrics.incrementAomqClamp();
        logger.info('event.aomq', {
            trigger,
            isBaseIn,
            amountIn: amountIn.toString(),
            quoteNotional: quoteNotional.toString(),
            spreadBps
        });
    };
    wsContract.on('TargetBaseXstarUpdated', recenterHandler);
    wsContract.on('AomqActivated', aomqHandler);
    return async () => {
        wsContract.off('TargetBaseXstarUpdated', recenterHandler);
        wsContract.off('AomqActivated', aomqHandler);
    };
}
async function runLoop(config, poolClient, metrics, oracleReader, logger, csvWriter) {
    const poolConfig = await poolClient.getConfig();
    const state = await poolClient.getState();
    const oracle = await oracleReader.sample();
    if (oracle.hc.status === 'error' && oracle.hc.reason === 'PrecompileError') {
        metrics.incrementPrecompileError();
    }
    if (oracle.pyth && oracle.pyth.status === 'error' && oracle.pyth.reason === 'PythError') {
        logger.debug('oracle.pyth.error', { detail: oracle.pyth.statusDetail });
    }
    const probes = await runSyntheticProbes({
        poolClient,
        poolState: state,
        poolConfig,
        oracle,
        sizeGrid: config.sizeGrid
    });
    const combinedRegime = aggregateRegimeFlags(probes);
    metrics.recordPoolState(state);
    metrics.recordOracle(oracle);
    metrics.recordRegime(combinedRegime);
    probes.forEach((probe, index) => {
        const rung = Math.floor(index / 2);
        metrics.recordProbe(probe, rung, probeRegimeLabel(probe));
        const resultLabel = mergeQuoteResult(probe);
        metrics.recordQuoteResult(resultLabel);
        if (!probe.success) {
            if (probe.status === 'PreviewStale') {
                metrics.incrementPreviewStale();
            }
            if (probe.status === 'AOMQClamp') {
                metrics.incrementAomqClamp();
            }
            if (probe.status === 'PrecompileError') {
                metrics.incrementPrecompileError();
            }
        }
    });
    const timestampMs = Date.now();
    metrics.recordTwoSided(timestampMs, detectTwoSided(probes));
    const csvRows = buildCsvRows(probes, timestampMs, {
        midHc: oracle.hc.midWad,
        midPyth: oracle.pyth?.midWad,
        confBps: oracle.pyth?.confBps,
        spreadBps: oracle.hc.spreadBps
    });
    await csvWriter.appendRows(csvRows);
    const summary = {
        oracle,
        poolState: state,
        probes,
        timestampMs
    };
    await csvWriter.writeSummary(summary);
    logger.debug('loop.metrics', {
        probes: probes.length,
        regime: combinedRegime.asArray.join('|') || 'calm'
    });
}
async function main() {
    const config = await loadConfig();
    const logger = createLogger(config.logLevel);
    const metrics = createMetricsManager(config);
    const providers = createProviderManager(config, (sample) => metrics.recordProviderSample(sample));
    const poolClient = new PoolClient(config, providers);
    const oracleReader = new OracleReader(config, providers);
    const csvWriter = createCsvWriter(config);
    await metrics.startServer();
    const tokens = await poolClient.getTokens();
    const poolConfig = await poolClient.getConfig();
    logger.info('shadowbot.init', {
        rpcUrl: config.rpcUrl,
        pool: config.poolAddress,
        labels: config.labels,
        sizes: config.sizeGrid.map((size) => size.toString()),
        tokens,
        featureFlags: poolConfig.featureFlags
    });
    const unsubscribe = await setupEventSubscriptions(config, providers, metrics, logger);
    let running = true;
    const signals = ['SIGINT', 'SIGTERM'];
    signals.forEach((signal) => {
        process.on(signal, () => {
            logger.info('signal.received', { signal });
            running = false;
        });
    });
    while (running) {
        const loopStarted = Date.now();
        try {
            await runLoop(config, poolClient, metrics, oracleReader, logger, csvWriter);
        }
        catch (error) {
            const detail = error instanceof Error ? error.message : String(error);
            logger.error('loop.error', { detail });
        }
        const elapsed = Date.now() - loopStarted;
        const waitMs = Math.max(config.intervalMs - elapsed, 0);
        if (!running)
            break;
        if (waitMs > 0) {
            await sleep(waitMs);
        }
    }
    if (unsubscribe) {
        await unsubscribe();
    }
    await metrics.stopServer();
    await providers.close();
    logger.info('shadowbot.stopped');
}
main().catch((error) => {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(JSON.stringify({ ts: new Date().toISOString(), level: 'error', msg: 'fatal', detail }));
    process.exit(1);
});
