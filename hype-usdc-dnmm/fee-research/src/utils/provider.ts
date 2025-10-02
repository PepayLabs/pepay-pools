import { ethers } from 'ethers';
import { requireEnv } from './env.js';

let hyperProvider: ethers.JsonRpcProvider | null = null;

export function getHyperProvider(): ethers.JsonRpcProvider {
  if (!hyperProvider) {
    const rpcUrl = requireEnv('HYPE_RPC_URL');
    hyperProvider = new ethers.JsonRpcProvider(rpcUrl, {
      chainId: 999,
      name: 'HyperEVM',
    });
  }
  return hyperProvider;
}
