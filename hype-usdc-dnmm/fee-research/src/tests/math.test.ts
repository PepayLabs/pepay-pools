import { describe, expect, it } from 'vitest';
import { computePriceImpactBps, computeEffectivePriceInPerOut } from '../utils/math.js';

describe('math utils', () => {
  it('computes price impact in bps', () => {
    const impact = computePriceImpactBps({ amountInTokens: 100, amountOutTokens: 99, idealOutTokens: 100 });
    expect(impact).toBeCloseTo(100);
  });

  it('computes effective price', () => {
    const price = computeEffectivePriceInPerOut(100, 50);
    expect(price).toBe(2);
  });
});
