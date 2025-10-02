import { describe, expect, it } from 'vitest';
import { ethers } from 'ethers';

import { HyperliquidAdapter } from '../adapters/hyperliquidAdapter.js';
import type { HyperliquidOrderBook } from '../adapters/hyperliquidClient.js';

class StubHyperliquidClient {
  constructor(readonly orderBook: HyperliquidOrderBook) {}

  async resolvePairSymbol(base: string, quote: string): Promise<string> {
    if (base !== 'HYPE' || quote !== 'USDC') {
      throw new Error('Unexpected pair resolution request');
    }
    return this.orderBook.pair;
  }

  async fetchOrderBook(_pair: string): Promise<HyperliquidOrderBook> {
    return this.orderBook;
  }
}

describe('HyperliquidAdapter', () => {
  const baseOrderBook: HyperliquidOrderBook = {
    pair: '@107',
    timestamp: 1_700_000_000_000,
    bids: [
      { px: '49', sz: '10', n: 1 },
      { px: '48', sz: '5', n: 1 },
    ],
    asks: [
      { px: '51', sz: '2', n: 1 },
      { px: '52', sz: '3', n: 1 },
    ],
  };

  it('quotes USDC->HYPE using asks depth', async () => {
    const adapter = new HyperliquidAdapter(new StubHyperliquidClient(baseOrderBook));
    const amountInWei = ethers.parseUnits('100', 6);

    const result = await adapter.quote({
      direction: 'USDC->HYPE',
      amount_in_tokens: '100',
      amount_in_wei: amountInWei,
      chain_id: 999,
      slippage_tolerance_bps: 50,
    });

    expect(result.success).toBe(true);
    expect(Number(result.amount_out_tokens)).toBeCloseTo(100 / 51, 6);
  });

  it('quotes HYPE->USDC using bids depth', async () => {
    const adapter = new HyperliquidAdapter(new StubHyperliquidClient(baseOrderBook));
    const amountInWei = ethers.parseUnits('3', 18);

    const result = await adapter.quote({
      direction: 'HYPE->USDC',
      amount_in_tokens: '3',
      amount_in_wei: amountInWei,
      chain_id: 999,
      slippage_tolerance_bps: 50,
    });

    expect(result.success).toBe(true);
    expect(Number(result.amount_out_tokens)).toBeCloseTo(3 * 49, 6);
  });

  it('fails when liquidity insufficient', async () => {
    const adapter = new HyperliquidAdapter(new StubHyperliquidClient(baseOrderBook));
    const amountInWei = ethers.parseUnits('1000', 6);

    const result = await adapter.quote({
      direction: 'USDC->HYPE',
      amount_in_tokens: '1000',
      amount_in_wei: amountInWei,
      chain_id: 999,
      slippage_tolerance_bps: 50,
    });

    expect(result.success).toBe(false);
    expect(result.failure_reason).toBe('insufficient_liquidity');
  });
});
