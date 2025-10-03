import { UniswapV3FactoryQuoterAdapter } from './uniswapV3FactoryQuoterAdapter.js';

export class HyperswapAdapter extends UniswapV3FactoryQuoterAdapter {
  constructor() {
    super({
      name: 'HyperSwap',
      factoryAddress: '0xB1c0fa0B789320044A6F623cFe5eBda9562602E3',
      quoterAddress: '0x03A918020F47d650b70138Cf564E154c7923C97f',
      feeCandidates: [100, 300, 500, 1000, 3000, 10000],
      sdkTag: 'hyperswap-v3@1',
    });
  }
}
