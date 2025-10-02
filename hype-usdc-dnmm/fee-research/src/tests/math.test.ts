import { describe, expect, it } from 'vitest';
import { computePriceImpactBps, computeEffectivePriceInPerOut } from '../utils/math.js';
import { amountInForDirection } from '../core/run.js';

describe('math utils', () => {
  it('computes price impact in bps', () => {
    const impact = computePriceImpactBps({ amountInTokens: 100, amountOutTokens: 99, idealOutTokens: 100 });
    expect(impact).toBeCloseTo(100);
  });

  it('computes effective price', () => {
    const price = computeEffectivePriceInPerOut(100, 50);
    expect(price).toBe(2);
  });

  it('converts USD notionals for USDC inputs without inflating notional', () => {
    const result = amountInForDirection('USDC->HYPE', 123.456789, 6, null);
    expect(result.tokens).toBe('123.456789');
    expect(result.wei).toBe(123456789n);
  });

  it('converts USD notionals for HYPE inputs using mid price', () => {
    const midPrice = 49.01777; // USDC per HYPE
    const result = amountInForDirection('HYPE->USDC', 100, 18, midPrice);
    const hypeTokens = parseFloat(result.tokens);
    expect(hypeTokens).toBeGreaterThan(1.9);
    expect(hypeTokens).toBeLessThan(2.1);
    expect(result.wei).toBeGreaterThan(0n);
  });
});
