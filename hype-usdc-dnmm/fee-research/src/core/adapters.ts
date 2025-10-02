import { AggregatorAdapter } from '../adapters/aggregatorAdapter.js';
import { HypertradeAdapter } from '../adapters/hypertradeAdapter.js';
import { KittenswapAdapter } from '../adapters/kittenswapAdapter.js';
import { HyperswapAdapter } from '../adapters/hyperswapAdapter.js';
import { UniswapLikeAdapter } from '../adapters/uniswapLikeAdapter.js';
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
    new UniswapLikeAdapter('Curve Finance', ['curve-finance', 'curve']),
    new UniswapLikeAdapter('HyperSwap', ['hyperswap-v3', 'hyperswap-v2', 'hyperswap']),
    new UniswapLikeAdapter('Hybra', ['hybraswap-v3', 'hybraswap', 'hybra']),
    new UniswapLikeAdapter('Upheaval Finance', ['upheaval-v3', 'upheaval']),
    new UniswapLikeAdapter('Kittenswap Finance', ['kittenswap_algebra', 'kittenswap']),
    new UniswapLikeAdapter('Gliquid', ['gliquid', 'gliquid-v2']),
    new UniswapLikeAdapter('Drip.Trade', ['drip.trade', 'drip-trade', 'driptrade']),
    new UniswapLikeAdapter('HyperBrick', ['hyperbrick']),
    new UniswapLikeAdapter('HX Finance', ['hx-finance', 'hxfinance']),
    new UniswapLikeAdapter('Project X', ['projectx', 'project-x']),
    new UniswapLikeAdapter('Hyperliquid', ['hyperliquid', 'hyperliquid-router']),
  ];
}
