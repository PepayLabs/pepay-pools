import { describe, expect, test } from 'vitest';
import { createScenarioEngine } from '../mock/scenarios.js';
import { createMockClock } from '../mock/mockClock.js';
import { MockPoolClient } from '../mock/mockPool.js';

const MIN_OUT = { calmBps: 10, fallbackBps: 20, clampMin: 5, clampMax: 25 };

function wad(value: number): bigint {
  return BigInt(Math.round(value * 1e18));
}

describe('MockPoolClient', () => {
  test('NEAR_FLOOR scenario flags near floor and partial fill', async () => {
    const clock = createMockClock();
    const { engine } = await createScenarioEngine('NEAR_FLOOR', clock.now());
    const pool = new MockPoolClient(engine, clock, 18, 6, MIN_OUT);

    const config = await pool.getConfig();
    const state = await pool.getState();
    const amountIn = wad(1);

    const quote = await pool.quoteExactIn(amountIn, true, 0, '0x');
    const regime = pool.computeRegimeFlags({
      poolState: state,
      config,
      usedFallback: quote.usedFallback,
      clampFlags: []
    });

    expect(regime.asArray).toContain('NearFloor');
    expect(quote.partialFillAmountIn).toBe(amountIn / 2n);
    const minOut = pool.computeGuaranteedMinOutBps(regime);
    expect(minOut).toBeGreaterThanOrEqual(MIN_OUT.clampMin);
  });
});
