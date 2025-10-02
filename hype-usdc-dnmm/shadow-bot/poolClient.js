import { Contract } from 'ethers';
import { IDNM_POOL_ABI } from './abis.js';
import { REGIME_BIT_VALUES } from './types.js';
const BPS = 10000n;
export class PoolClient {
    runtime;
    providers;
    contract;
    tokensCache;
    configCache;
    constructor(runtime, providers, contractOverride) {
        this.runtime = runtime;
        this.providers = providers;
        this.contract = contractOverride ?? new Contract(runtime.poolAddress, IDNM_POOL_ABI, providers.rpc);
    }
    async getTokens(force = false) {
        if (!force && this.tokensCache)
            return this.tokensCache;
        const result = await this.providers.request('tokens', () => this.contract.tokens());
        const tokens = {
            base: result.baseToken,
            quote: result.quoteToken,
            baseDecimals: Number(result.baseDecimals),
            quoteDecimals: Number(result.quoteDecimals),
            baseScale: BigInt(result.baseScale),
            quoteScale: BigInt(result.quoteScale)
        };
        this.tokensCache = tokens;
        return tokens;
    }
    async getConfig(force = false) {
        if (!force && this.configCache)
            return this.configCache;
        const [oracleRaw, inventoryRaw, feeRaw, makerRaw, flagsRaw] = await Promise.all([
            this.providers.request('oracleConfig', () => this.contract.oracleConfig()),
            this.providers.request('inventoryConfig', () => this.contract.inventoryConfig()),
            this.providers.request('feeConfig', () => this.contract.feeConfig()),
            this.providers.request('makerConfig', () => this.contract.makerConfig()),
            this.providers.request('featureFlags', () => this.contract.featureFlags())
        ]);
        const oracleConfig = {
            maxAgeSec: Number(oracleRaw.maxAgeSec ?? oracleRaw[0]),
            stallWindowSec: Number(oracleRaw.stallWindowSec ?? oracleRaw[1]),
            confCapBpsSpot: Number(oracleRaw.confCapBpsSpot ?? oracleRaw[2]),
            confCapBpsStrict: Number(oracleRaw.confCapBpsStrict ?? oracleRaw[3]),
            divergenceBps: Number(oracleRaw.divergenceBps ?? oracleRaw[4]),
            allowEmaFallback: Boolean(oracleRaw.allowEmaFallback ?? oracleRaw[5]),
            confWeightSpreadBps: Number(oracleRaw.confWeightSpreadBps ?? oracleRaw[6]),
            confWeightSigmaBps: Number(oracleRaw.confWeightSigmaBps ?? oracleRaw[7]),
            confWeightPythBps: Number(oracleRaw.confWeightPythBps ?? oracleRaw[8]),
            sigmaEwmaLambdaBps: Number(oracleRaw.sigmaEwmaLambdaBps ?? oracleRaw[9]),
            divergenceAcceptBps: Number(oracleRaw.divergenceAcceptBps ?? oracleRaw[10]),
            divergenceSoftBps: Number(oracleRaw.divergenceSoftBps ?? oracleRaw[11]),
            divergenceHardBps: Number(oracleRaw.divergenceHardBps ?? oracleRaw[12]),
            haircutMinBps: Number(oracleRaw.haircutMinBps ?? oracleRaw[13]),
            haircutSlopeBps: Number(oracleRaw.haircutSlopeBps ?? oracleRaw[14])
        };
        const inventoryConfig = {
            targetBaseXstar: BigInt(inventoryRaw.targetBaseXstar ?? inventoryRaw[0]),
            floorBps: Number(inventoryRaw.floorBps ?? inventoryRaw[1]),
            recenterThresholdPct: Number(inventoryRaw.recenterThresholdPct ?? inventoryRaw[2]),
            invTiltBpsPer1pct: Number(inventoryRaw.invTiltBpsPer1pct ?? inventoryRaw[3]),
            invTiltMaxBps: Number(inventoryRaw.invTiltMaxBps ?? inventoryRaw[4]),
            tiltConfWeightBps: Number(inventoryRaw.tiltConfWeightBps ?? inventoryRaw[5]),
            tiltSpreadWeightBps: Number(inventoryRaw.tiltSpreadWeightBps ?? inventoryRaw[6])
        };
        const feeConfig = {
            baseBps: Number(feeRaw.baseBps ?? feeRaw[0]),
            alphaNumerator: Number(feeRaw.alphaNumerator ?? feeRaw[1]),
            alphaDenominator: Number(feeRaw.alphaDenominator ?? feeRaw[2]),
            betaInvDevNumerator: Number(feeRaw.betaInvDevNumerator ?? feeRaw[3]),
            betaInvDevDenominator: Number(feeRaw.betaInvDevDenominator ?? feeRaw[4]),
            capBps: Number(feeRaw.capBps ?? feeRaw[5]),
            decayPctPerBlock: Number(feeRaw.decayPctPerBlock ?? feeRaw[6]),
            gammaSizeLinBps: Number(feeRaw.gammaSizeLinBps ?? feeRaw[7]),
            gammaSizeQuadBps: Number(feeRaw.gammaSizeQuadBps ?? feeRaw[8]),
            sizeFeeCapBps: Number(feeRaw.sizeFeeCapBps ?? feeRaw[9])
        };
        const makerConfig = {
            s0Notional: BigInt(makerRaw.s0Notional ?? makerRaw[0]),
            ttlMs: Number(makerRaw.ttlMs ?? makerRaw[1]),
            alphaBboBps: Number(makerRaw.alphaBboBps ?? makerRaw[2]),
            betaFloorBps: Number(makerRaw.betaFloorBps ?? makerRaw[3])
        };
        const featureFlags = {
            blendOn: Boolean(flagsRaw.blendOn ?? flagsRaw[0]),
            parityCiOn: Boolean(flagsRaw.parityCiOn ?? flagsRaw[1]),
            debugEmit: Boolean(flagsRaw.debugEmit ?? flagsRaw[2]),
            enableSoftDivergence: Boolean(flagsRaw.enableSoftDivergence ?? flagsRaw[3]),
            enableSizeFee: Boolean(flagsRaw.enableSizeFee ?? flagsRaw[4]),
            enableBboFloor: Boolean(flagsRaw.enableBboFloor ?? flagsRaw[5]),
            enableInvTilt: Boolean(flagsRaw.enableInvTilt ?? flagsRaw[6]),
            enableAOMQ: Boolean(flagsRaw.enableAOMQ ?? flagsRaw[7]),
            enableRebates: Boolean(flagsRaw.enableRebates ?? flagsRaw[8]),
            enableAutoRecenter: Boolean(flagsRaw.enableAutoRecenter ?? flagsRaw[9])
        };
        const config = {
            oracle: oracleConfig,
            inventory: inventoryConfig,
            fee: feeConfig,
            maker: makerConfig,
            featureFlags
        };
        this.configCache = config;
        return config;
    }
    async getState() {
        const [reservesRaw, lastMidRaw, snapshotAgeRaw] = await Promise.all([
            this.providers.request('reserves', () => this.contract.reserves()),
            this.providers.request('lastMid', () => this.contract.lastMid()),
            this.providers.request('previewSnapshotAge', () => this.contract.previewSnapshotAge())
        ]);
        const state = {
            baseReserves: BigInt(reservesRaw.baseReserves ?? reservesRaw[0]),
            quoteReserves: BigInt(reservesRaw.quoteReserves ?? reservesRaw[1]),
            lastMidWad: BigInt(lastMidRaw),
            snapshotAgeSec: Number(snapshotAgeRaw.ageSec ?? snapshotAgeRaw[0]),
            snapshotTimestamp: Number(snapshotAgeRaw.snapshotTimestamp ?? snapshotAgeRaw[1])
        };
        return state;
    }
    async getPreviewLadder(s0BaseWad) {
        const result = await this.providers.request('previewLadder', () => this.contract.getFunction('previewLadder').staticCall(s0BaseWad));
        const rows = [];
        const sizes = Array.from(result.sizesBaseWad ?? result[0] ?? []);
        const askFees = Array.from(result.askFeeBps ?? result[1] ?? []);
        const bidFees = Array.from(result.bidFeeBps ?? result[2] ?? []);
        const askClamped = Array.from(result.askClamped ?? result[3] ?? []);
        const bidClamped = Array.from(result.bidClamped ?? result[4] ?? []);
        for (let i = 0; i < sizes.length; i += 1) {
            rows.push({
                sizeWad: BigInt(sizes[i]),
                askFeeBps: Number(askFees[i] ?? 0n),
                bidFeeBps: Number(bidFees[i] ?? 0n),
                askClamped: Boolean(askClamped[i]),
                bidClamped: Boolean(bidClamped[i])
            });
        }
        return {
            rows,
            snapshotTimestamp: Number(result.snapshotTimestamp ?? result[5] ?? 0),
            snapshotMidWad: BigInt(result.snapshotMid ?? result[6] ?? 0n)
        };
    }
    async previewFees(sizes) {
        const result = await this.providers.request('previewFees', () => this.contract.getFunction('previewFees').staticCall(sizes));
        const askFees = Array.from(result.askFeeBps ?? result[0] ?? []).map((value) => Number(value));
        const bidFees = Array.from(result.bidFeeBps ?? result[1] ?? []).map((value) => Number(value));
        return { ask: askFees, bid: bidFees };
    }
    async quoteExactIn(amountIn, isBaseIn, oracleMode, oracleData) {
        const func = this.contract.getFunction('quoteSwapExactIn');
        const result = await this.providers.request('quoteSwapExactIn', () => func.staticCall(amountIn, isBaseIn, oracleMode, oracleData));
        return {
            amountOut: BigInt(result.amountOut ?? result[0]),
            midUsed: BigInt(result.midUsed ?? result[1]),
            feeBpsUsed: Number(result.feeBpsUsed ?? result[2]),
            partialFillAmountIn: BigInt(result.partialFillAmountIn ?? result[3]),
            usedFallback: Boolean(result.usedFallback ?? result[4]),
            reason: String(result.reason ?? result[5])
        };
    }
    computeRegimeFlags(params) {
        const { poolState, config, usedFallback, clampFlags } = params;
        let bitmask = 0;
        const flags = new Set();
        clampFlags.forEach((flag) => flags.add(flag));
        if (usedFallback) {
            flags.add('Fallback');
        }
        if (config.featureFlags.enableSizeFee) {
            flags.add('SizeFee');
        }
        if (config.featureFlags.enableInvTilt) {
            flags.add('InvTilt');
        }
        if (isNearFloor(poolState, config.inventory)) {
            flags.add('NearFloor');
        }
        for (const flag of flags) {
            bitmask |= REGIME_BIT_VALUES[flag];
        }
        return {
            bitmask,
            asArray: Array.from(flags)
        };
    }
    computeGuaranteedMinOutBps(flags) {
        const { calmBps, fallbackBps, clampMin, clampMax } = this.runtime.guaranteedMinOut;
        const needsFallback = flags.asArray.includes('Fallback') || flags.asArray.includes('AOMQ');
        const unclamped = needsFallback ? fallbackBps : calmBps;
        return Math.min(Math.max(unclamped, clampMin), clampMax);
    }
}
function isNearFloor(state, inventory) {
    if (inventory.floorBps === 0)
        return false;
    const floorAmount = (inventory.targetBaseXstar * BigInt(inventory.floorBps)) / BPS;
    const tolerance = inventory.targetBaseXstar / 100n; // 1% tolerance
    return state.baseReserves <= floorAmount + tolerance;
}
