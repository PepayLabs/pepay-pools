import { AggregatorAdapter } from '../adapters/aggregatorAdapter.js';
import { HypertradeAdapter } from '../adapters/hypertradeAdapter.js';
import { KittenswapAdapter } from '../adapters/kittenswapAdapter.js';
import { HyperswapAdapter } from '../adapters/hyperswapAdapter.js';
import { HypertradeDexAdapter } from '../adapters/hypertradeDexAdapter.js';
import { BaseAdapter } from '../adapters/base.js';

export function buildAdapters(): BaseAdapter[] {
  return [
    new HypertradeAdapter(),
    new KittenswapAdapter(),
    new HyperswapAdapter(),
    new AggregatorAdapter('1inch'),
    new AggregatorAdapter('0x'),
    new AggregatorAdapter('Odos'),
    new AggregatorAdapter('ParaSwap'),
    new HypertradeDexAdapter('Curve Finance', ['curve-finance', 'curve']),
    new HypertradeDexAdapter('HyperSwap', ['hyperswap-v3', 'hyperswap-v2', 'hyperswap']),
    new HypertradeDexAdapter('Hybra', ['hybraswap-v3', 'hybraswap', 'hybra']),
    new HypertradeDexAdapter('Upheaval Finance', ['upheaval-v3', 'upheaval']),
    new HypertradeDexAdapter('Kittenswap Finance', ['kittenswap_algebra', 'kittenswap']),
    new HypertradeDexAdapter('Gliquid', ['gliquid', 'gliquid-v2']),
    new HypertradeDexAdapter('Drip.Trade', ['drip.trade', 'drip-trade', 'driptrade']),
    new HypertradeDexAdapter('HyperBrick', ['hyperbrick']),
    new HypertradeDexAdapter('HX Finance', ['hx-finance', 'hxfinance']),
    new HypertradeDexAdapter('Project X', ['projectx', 'project-x']),
    new HypertradeDexAdapter('Hyperliquid', ['hyperliquid', 'hyperliquid-router']),
  ];
}
