import { describe, expect, test } from 'vitest';
import { createScenarioEngine } from '../mock/scenarios.js';
import { createMockClock } from '../mock/mockClock.js';
import { MockOracleReader } from '../mock/mockOracle.js';

describe('MockOracleReader', () => {
  test('CALM scenario provides tight spread and low confidence', async () => {
    const clock = createMockClock();
    const { engine } = await createScenarioEngine('CALM', clock.now());
    const reader = new MockOracleReader(engine, clock);
    const snapshot = await reader.sample();

    expect(snapshot.hc.status).toBe('ok');
    expect(snapshot.hc.spreadBps).toBe(10);
    expect(snapshot.pyth?.confBps).toBe(20);
  });

  test('STALE_PYTH scenario backdates publish time and marks details', async () => {
    const clock = createMockClock();
    const { engine } = await createScenarioEngine('STALE_PYTH', clock.now());
    const reader = new MockOracleReader(engine, clock);
    const snapshot = await reader.sample();

    expect(snapshot.pyth?.status).toBe('ok');
    expect(snapshot.pyth?.statusDetail).toBe('stale');
    expect(snapshot.pyth?.publishTimeSec).toBeLessThan(clock.nowSeconds());
  });
});
