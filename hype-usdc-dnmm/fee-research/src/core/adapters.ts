import { AggregatorAdapter } from '../adapters/aggregatorAdapter.js';
import { HypertradeAdapter } from '../adapters/hypertradeAdapter.js';
import { KittenswapAdapter } from '../adapters/kittenswapAdapter.js';
import { HyperswapAdapter } from '../adapters/hyperswapAdapter.js';
import { HypertradeDexAdapter } from '../adapters/hypertradeDexAdapter.js';
import { HyperliquidAdapter } from '../adapters/hyperliquidAdapter.js';
import { BaseAdapter } from '../adapters/base.js';

export function buildAdapters(): BaseAdapter[] {
  return [
    new HyperliquidAdapter(),
    new HypertradeAdapter(),
    new KittenswapAdapter(),
    new HyperswapAdapter(),
    new AggregatorAdapter('1inch'),
    new AggregatorAdapter('0x'),
    new AggregatorAdapter('Odos'),
    new AggregatorAdapter('ParaSwap'),
    new HypertradeDexAdapter('Curve Finance', ['curve-finance', 'curve']),
    new HypertradeDexAdapter('Hybra', ['hybraswap-v3', 'hybraswap', 'hybra']),
    new HypertradeDexAdapter('Upheaval Finance', ['upheaval-v3', 'upheaval']),
    new HypertradeDexAdapter('Gliquid', ['gliquid', 'gliquid-v2']),
    new HypertradeDexAdapter('Drip.Trade', ['drip.trade', 'drip-trade', 'driptrade']),
    new HypertradeDexAdapter('HyperBrick', ['hyperbrick']),
    new HypertradeDexAdapter('HX Finance', ['hx-finance', 'hxfinance']),
    new HypertradeDexAdapter('Project X', ['projectx', 'project-x']),
  ];
}
