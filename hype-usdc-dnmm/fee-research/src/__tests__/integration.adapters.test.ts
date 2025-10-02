import { describe, expect, it } from 'vitest';
import { AggregatorAdapter } from '../adapters/aggregatorAdapter.js';

describe('AggregatorAdapter', () => {
  it('marks HyperEVM unsupported for 1inch by default', async () => {
    const adapter = new AggregatorAdapter('1inch');
    expect(await adapter.supports(999)).toBe(false);
  });
});
