import { AggregatorAdapter } from '../adapters/aggregatorAdapter.js';
import { CurveAdapter } from '../adapters/curveAdapter.js';
import { UniswapLikeAdapter } from '../adapters/uniswapLikeAdapter.js';
import { BaseAdapter } from '../adapters/base.js';

export function buildAdapters(): BaseAdapter[] {
  return [
    new AggregatorAdapter('1inch'),
    new AggregatorAdapter('0x'),
    new AggregatorAdapter('Odos'),
    new AggregatorAdapter('ParaSwap'),
    new CurveAdapter(),
    new UniswapLikeAdapter('HyperSwap'),
    new UniswapLikeAdapter('Hybra'),
    new UniswapLikeAdapter('Upheaval Finance'),
    new UniswapLikeAdapter('Kittenswap Finance'),
    new UniswapLikeAdapter('Gliquid'),
    new UniswapLikeAdapter('Drip.Trade'),
    new UniswapLikeAdapter('HyperBrick'),
    new UniswapLikeAdapter('HX Finance'),
    new UniswapLikeAdapter('Project X'),
    new UniswapLikeAdapter('Hyperliquid'),
  ];
}
