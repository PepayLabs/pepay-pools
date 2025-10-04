import { ChainClient } from '../types.js';
import { MockClock } from './mockClock.js';

function gweiToWei(gwei: number | undefined, fallback: bigint): bigint {
  if (gwei === undefined || Number.isNaN(gwei)) return fallback;
  return BigInt(Math.floor(gwei * 1e9));
}

export class NullChainClient implements ChainClient {
  private readonly gasPriceWei: bigint;

  constructor(private readonly clock: MockClock, gasPriceGwei?: number) {
    this.gasPriceWei = gweiToWei(gasPriceGwei, 25n * 10n ** 9n);
  }

  getRpcProvider() {
    return undefined;
  }

  getWebSocketProvider() {
    return undefined;
  }

  async callContract(): Promise<string> {
    throw new Error('Mock chain client does not support eth_call');
  }

  async request<T>(_label: string, fn: () => Promise<T> | T): Promise<T> {
    return Promise.resolve(fn());
  }

  async getBlockNumber(): Promise<number> {
    return this.clock.getBlockNumber();
  }

  async getBlockTimestamp(): Promise<number> {
    return this.clock.nowSeconds();
  }

  async getGasPrice(): Promise<bigint> {
    return this.gasPriceWei;
  }

  on(): void {
    // no-op in mock mode
  }

  async close(): Promise<void> {
    // nothing to clean up
  }
}

export function createNullChainClient(clock: MockClock, gasPriceGwei?: number): NullChainClient {
  return new NullChainClient(clock, gasPriceGwei);
}
