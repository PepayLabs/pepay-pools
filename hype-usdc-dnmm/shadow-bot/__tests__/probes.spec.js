import { describe, expect, it } from 'vitest';
import { runSyntheticProbes } from '../probes.js';
const poolConfig = {
    oracle: {
        maxAgeSec: 30,
        stallWindowSec: 120,
        confCapBpsSpot: 50,
        confCapBpsStrict: 60,
        divergenceBps: 25,
        allowEmaFallback: true,
        confWeightSpreadBps: 100,
        confWeightSigmaBps: 200,
        confWeightPythBps: 300,
        sigmaEwmaLambdaBps: 400,
        divergenceAcceptBps: 15,
        divergenceSoftBps: 20,
        divergenceHardBps: 30,
        haircutMinBps: 1,
        haircutSlopeBps: 2
    },
    inventory: {
        targetBaseXstar: 100n,
        floorBps: 10,
        recenterThresholdPct: 5,
        invTiltBpsPer1pct: 0,
        invTiltMaxBps: 0,
        tiltConfWeightBps: 0,
        tiltSpreadWeightBps: 0
    },
    fee: {
        baseBps: 10,
        alphaNumerator: 1,
        alphaDenominator: 100,
        betaInvDevNumerator: 1,
        betaInvDevDenominator: 50,
        capBps: 30,
        decayPctPerBlock: 1,
        gammaSizeLinBps: 0,
        gammaSizeQuadBps: 0,
        sizeFeeCapBps: 50
    },
    maker: {
        s0Notional: 1000n,
        ttlMs: 250,
        alphaBboBps: 5,
        betaFloorBps: 5
    },
    featureFlags: {
        blendOn: true,
        parityCiOn: false,
        debugEmit: false,
        enableSoftDivergence: true,
        enableSizeFee: true,
        enableBboFloor: false,
        enableInvTilt: true,
        enableAOMQ: true,
        enableRebates: false,
        enableAutoRecenter: true
    }
};
const poolState = {
    baseReserves: 120n,
    quoteReserves: 3600n,
    lastMidWad: 30n * 10n ** 18n
};
describe('runSyntheticProbes', () => {
    it('produces probe rows with clamp flags and regimes', async () => {
        const regime = { bitmask: 0b11, asArray: ['AOMQ', 'Fallback'] };
        const poolClientStub = {
            quoteExactIn: (amountIn, isBaseIn) => {
                if (isBaseIn) {
                    return Promise.resolve({
                        amountOut: amountIn * 30n,
                        midUsed: 30n * 10n ** 18n,
                        feeBpsUsed: 12,
                        partialFillAmountIn: 0n,
                        usedFallback: false,
                        reason: '0x414f4d512d434c414d500000000000000000000000000000000000000000'
                    });
                }
                return Promise.resolve({
                    amountOut: amountIn / 30n,
                    midUsed: 30n * 10n ** 18n,
                    feeBpsUsed: 15,
                    partialFillAmountIn: 0n,
                    usedFallback: true,
                    reason: '0x' // triggers fallback via usedFallback
                });
            },
            computeRegimeFlags: () => regime,
            computeGuaranteedMinOutBps: () => 20
        };
        const oracle = {
            observedAtMs: Date.now(),
            hc: {
                status: 'ok',
                reason: 'OK',
                midWad: 30n * 10n ** 18n,
                bidWad: 29n * 10n ** 18n,
                askWad: 31n * 10n ** 18n,
                spreadBps: 200
            },
            pyth: undefined
        };
        const probes = await runSyntheticProbes({
            poolClient: poolClientStub,
            poolState,
            poolConfig,
            oracle: oracle,
            sizeGrid: [1n * 10n ** 18n]
        });
        expect(probes).toHaveLength(2);
        const baseProbe = probes.find((probe) => probe.side === 'base_in');
        const quoteProbe = probes.find((probe) => probe.side === 'quote_in');
        expect(baseProbe.clampFlags).toContain('AOMQ');
        expect(quoteProbe.riskBits).toContain('Fallback');
        expect(quoteProbe.usedFallback).toBe(true);
        expect(typeof baseProbe.latencyMs).toBe('number');
    });
});
