import { describe, expect, test } from 'vitest';
import { runSyntheticProbes } from '../probes.js';
import { createScenarioEngine } from '../mock/scenarios.js';
import { createMockClock } from '../mock/mockClock.js';
import { MockPoolClient } from '../mock/mockPool.js';
import { MockOracleReader } from '../mock/mockOracle.js';

const MIN_OUT = { calmBps: 10, fallbackBps: 20, clampMin: 5, clampMax: 25 };

function wad(value: number): bigint {
  return BigInt(Math.round(value * 1e18));
}

describe('runSyntheticProbes', () => {
  test('CALM scenario yields successful probes without fallback', async () => {
    const clock = createMockClock();
    const { engine } = await createScenarioEngine('CALM', clock.now());
    const pool = new MockPoolClient(engine, clock, 18, 6, MIN_OUT);
    const oracleReader = new MockOracleReader(engine, clock);
    const poolConfig = await pool.getConfig();
    const poolState = await pool.getState();
    const oracle = await oracleReader.sample();

    const probes = await runSyntheticProbes({
      poolClient: pool,
      poolState,
      poolConfig,
      oracle,
      sizeGrid: [wad(0.5), wad(1)]
    });

    expect(probes.length).toBe(4);
    expect(probes.every((probe) => probe.success)).toBe(true);
    expect(probes.every((probe) => !probe.riskBits.includes('Fallback'))).toBe(true);
  });

  test('AOMQ_ON scenario marks risk bits', async () => {
    const clock = createMockClock();
    const { engine } = await createScenarioEngine('AOMQ_ON', clock.now());
    const pool = new MockPoolClient(engine, clock, 18, 6, MIN_OUT);
    const oracleReader = new MockOracleReader(engine, clock);
    const poolConfig = await pool.getConfig();
    const poolState = await pool.getState();
    const oracle = await oracleReader.sample();

    const probes = await runSyntheticProbes({
      poolClient: pool,
      poolState,
      poolConfig,
      oracle,
      sizeGrid: [wad(1)]
    });

    expect(probes.some((probe) => probe.riskBits.includes('AOMQ'))).toBe(true);
  });
});
