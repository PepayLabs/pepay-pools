import { describe, expect, it } from 'vitest';
import { SimOracleReader } from '../sim/simOracle.js';
import { RiskScenarioDefinition } from '../types.js';

const BASE_SCENARIO: RiskScenarioDefinition = {
  id: 'calm',
  bboSpreadBps: [5, 15],
  sigmaBps: [10, 25]
};

describe('SimOracleReader', () => {
  it('produces mid/spread/sigma samples within scenario bounds', async () => {
    const reader = new SimOracleReader({
      seed: 42,
      scenario: BASE_SCENARIO,
      tickMs: 250
    });

    const sample = await reader.sample();
    expect(sample.hc.sigmaBps).toBeDefined();
    expect(sample.hc.spreadBps).toBeGreaterThanOrEqual(BASE_SCENARIO.bboSpreadBps![0]);
    expect(sample.hc.spreadBps).toBeLessThanOrEqual(BASE_SCENARIO.bboSpreadBps![1]);
    expect(sample.hc.sigmaBps).toBeGreaterThanOrEqual(BASE_SCENARIO.sigmaBps![0]);
    expect(sample.hc.sigmaBps).toBeLessThanOrEqual(BASE_SCENARIO.sigmaBps![1]);
    expect(sample.hc.midWad).toBeDefined();
  });

  it('emits Pyth outages when drop rate is high', async () => {
    const reader = new SimOracleReader({
      seed: 7,
      scenario: {
        id: 'dropout',
        pythDropRate: 1
      },
      tickMs: 250
    });

    const sample = await reader.sample();
    expect(sample.pyth?.status).toBe('error');
    expect(sample.pyth?.reason).toBe('PythError');
  });
});
