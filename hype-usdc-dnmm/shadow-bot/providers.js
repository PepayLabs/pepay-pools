import { JsonRpcProvider, WebSocketProvider } from 'ethers';
function delay(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
async function withTimeout(promise, timeoutMs, method) {
    if (timeoutMs <= 0)
        return promise;
    let timer;
    const timeoutPromise = new Promise((_, reject) => {
        timer = setTimeout(() => {
            reject(new Error(`${method} timed out after ${timeoutMs}ms`));
        }, timeoutMs);
    });
    try {
        const result = await Promise.race([promise, timeoutPromise]);
        return result;
    }
    finally {
        if (timer)
            clearTimeout(timer);
    }
}
export class ProviderManager {
    rpc;
    ws;
    retryAttempts;
    retryBackoffMs;
    timeoutMs;
    onHealthSample;
    constructor(config, onHealthSample) {
        this.rpc = new JsonRpcProvider(config.rpcUrl, config.chainId ?? undefined);
        this.timeoutMs = config.sampling.timeoutMs;
        this.retryAttempts = config.sampling.retryAttempts;
        this.retryBackoffMs = config.sampling.retryBackoffMs;
        this.onHealthSample = onHealthSample;
        if (config.wsUrl) {
            this.ws = new WebSocketProvider(config.wsUrl, config.chainId ?? undefined);
            this.ws.on('error', (error) => {
                this.publishHealth(false, 'ws', error instanceof Error ? error : new Error(String(error)));
            });
        }
    }
    async callContract(request, label) {
        const executor = () => this.rpc.call(request);
        return this.executeWithRetries(executor, label);
    }
    async request(label, fn) {
        return this.executeWithRetries(fn, label);
    }
    async getBlockNumber(label = 'getBlockNumber') {
        const executor = () => this.rpc.getBlockNumber();
        return this.executeWithRetries(executor, label);
    }
    async getBlockTimestamp(label = 'getBlockTimestamp') {
        const executor = async () => {
            const block = await this.rpc.getBlock('latest');
            if (!block)
                throw new Error('Latest block unavailable');
            return Number(block.timestamp);
        };
        return this.executeWithRetries(executor, label);
    }
    async getGasPrice(label = 'getGasPrice') {
        const executor = async () => {
            const hex = await this.rpc.send('eth_gasPrice', []);
            return BigInt(hex);
        };
        return this.executeWithRetries(executor, label);
    }
    on(event, handler) {
        this.ws?.on('close', handler);
    }
    async close() {
        await this.rpc.destroy();
        if (this.ws) {
            await this.ws.destroy();
        }
    }
    async executeWithRetries(executor, method) {
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
            }
            catch (error) {
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
    publishHealth(success, method, error, latencyMs = 0) {
        if (!this.onHealthSample)
            return;
        this.onHealthSample({ success, method, latencyMs, error });
    }
}
export function createProviderManager(config, onHealthSample) {
    return new ProviderManager(config, onHealthSample);
}
