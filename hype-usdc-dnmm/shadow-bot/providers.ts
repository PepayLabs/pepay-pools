import { JsonRpcProvider, WebSocketProvider } from 'ethers';
import { ChainRuntimeConfig, ChainClient, ProviderHealthSample } from './types.js';

type HealthCallback = (sample: ProviderHealthSample) => void;

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function withTimeout<T>(promise: Promise<T>, timeoutMs: number, method: string): Promise<T> {
  if (timeoutMs <= 0) return promise;
  let timer: NodeJS.Timeout | undefined;
  const timeoutPromise = new Promise<T>((_, reject) => {
    timer = setTimeout(() => {
      reject(new Error(`${method} timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });
  try {
    const result = await Promise.race([promise, timeoutPromise]);
    return result as T;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

export class LiveChainClient implements ChainClient {
  private readonly rpc: JsonRpcProvider;
  private readonly ws?: WebSocketProvider;

  private readonly retryAttempts: number;
  private readonly retryBackoffMs: number;
  private readonly timeoutMs: number;

  constructor(private readonly config: ChainRuntimeConfig, private readonly onHealthSample?: HealthCallback) {
    this.rpc = new JsonRpcProvider(config.rpcUrl, config.chainId ?? undefined);
    this.retryAttempts = 3;
    this.retryBackoffMs = 500;
    this.timeoutMs = 7_500;

    if (config.wsUrl) {
      this.ws = new WebSocketProvider(config.wsUrl, config.chainId ?? undefined);
      this.ws.on('error', (error) => {
        this.publishHealth(false, 'ws', error instanceof Error ? error : new Error(String(error)));
      });
    }
  }

  getRpcProvider(): JsonRpcProvider | undefined {
    return this.rpc;
  }

  getWebSocketProvider(): WebSocketProvider | undefined {
    return this.ws;
  }

  async callContract(request: { to: string; data: string }, label: string): Promise<string> {
    const executor = () => this.rpc.call(request);
    return this.executeWithRetries(executor, label);
  }

  async request<T>(label: string, fn: () => Promise<T>): Promise<T> {
    return this.executeWithRetries(fn, label);
  }

  async getBlockNumber(label = 'getBlockNumber'): Promise<number> {
    const executor = () => this.rpc.getBlockNumber();
    return this.executeWithRetries(executor, label);
  }

  async getBlockTimestamp(label = 'getBlockTimestamp'): Promise<number> {
    const executor = async () => {
      const block = await this.rpc.getBlock('latest');
      if (!block) throw new Error('Latest block unavailable');
      return Number(block.timestamp);
    };
    return this.executeWithRetries(executor, label);
  }

  async getGasPrice(label = 'getGasPrice'): Promise<bigint> {
    const executor = async () => {
      const hex = await this.rpc.send('eth_gasPrice', []);
      return BigInt(hex);
    };
    return this.executeWithRetries(executor, label);
  }

  on(event: 'close', handler: (code: number) => void): void {
    if (event !== 'close') return;
    this.ws?.on('close', handler);
  }

  async close(): Promise<void> {
    await this.rpc.destroy();
    if (this.ws) {
      await this.ws.destroy();
    }
  }

  private async executeWithRetries<T>(executor: () => Promise<T>, method: string): Promise<T> {
    let attempt = 0;
    let delayMs = this.retryBackoffMs;
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const started = Date.now();
      try {
        const result = await withTimeout(executor(), this.timeoutMs, method);
        const latencyMs = Date.now() - started;
        this.publishHealth(true, method, undefined, latencyMs);
        return result;
      } catch (error) {
        const latencyMs = Date.now() - started;
        this.publishHealth(false, method, error instanceof Error ? error : new Error(String(error)), latencyMs);
        attempt += 1;
        if (attempt >= this.retryAttempts) {
          throw error instanceof Error ? error : new Error(String(error));
        }
        await delay(delayMs);
        delayMs *= 2;
      }
    }
  }

  private publishHealth(success: boolean, method: string, error?: Error, latencyMs = 0): void {
    if (!this.onHealthSample) return;
    this.onHealthSample({ success, method, latencyMs, error });
  }
}

export function createLiveChainClient(config: ChainRuntimeConfig, onHealthSample?: HealthCallback): LiveChainClient {
  return new LiveChainClient(config, onHealthSample);
}

export type { HealthCallback };
