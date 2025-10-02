import { BaseAdapter } from './base.js';
import { QuoteParams, QuoteResult, AdapterDocsMeta, QuoteDirection, TokenPair } from '../types.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { findToken } from '../registries/tokens.js';
import { logger } from '../utils/logger.js';

const SUPPORTED_CHAINS: Record<string, number[]> = {
  '1inch': [1, 56, 137, 42161, 10, 8453, 43114],
  '0x': [1, 56, 137, 42161, 10, 8453],
  Odos: [1, 56, 137, 42161, 10, 8453, 42220],
  ParaSwap: [1, 56, 137, 42161, 10, 8453, 43114],
};

export class AggregatorAdapter extends BaseAdapter {
  private readonly aggregatorName: string;
  private docsCache: AdapterDocsMeta | null = null;

  constructor(name: string) {
    super();
    this.aggregatorName = name;
  }

  override name(): string {
    return `${this.aggregatorName} Aggregator`;
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((d) => d.name.toLowerCase() === this.aggregatorName.toLowerCase());
    const meta: AdapterDocsMeta = {
      official_docs_url: entry?.official_docs_url ?? null,
      sdk_package_name: entry?.sdk_package_name ?? null,
      sdk_repo_url: entry?.sdk_repo_url ?? null,
      http_quote_base_url: entry?.http_quote_base_url ?? null,
    };
    this.docsCache = meta;
    return meta;
  }

  override async supports(chain_id: number): Promise<boolean> {
    const supported = SUPPORTED_CHAINS[this.aggregatorName]?.includes(chain_id) ?? false;
    return supported;
  }

  override async resolveTokens(direction: QuoteDirection): Promise<TokenPair> {
    const chainId = 999; // HyperEVM default
    const inSymbol = direction === 'USDC->HYPE' ? 'USDC' : 'WHYPE';
    const outSymbol = direction === 'USDC->HYPE' ? 'WHYPE' : 'USDC';
    const tokenIn = await findToken(inSymbol, chainId);
    const tokenOut = await findToken(outSymbol, chainId);
    if (!tokenIn || !tokenOut) {
      throw new Error(`Missing token configuration for ${inSymbol}/${outSymbol} on chain ${chainId}`);
    }
    return { in: tokenIn, out: tokenOut };
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const docs = await this.docs();
    const supported = await this.supports(params.chain_id);
    if (!supported) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: null,
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: 'chain_not_supported',
      };
    }

    if (!docs.http_quote_base_url) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: null,
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: 'missing_http_endpoint',
      };
    }

    logger.warn({ adapter: this.aggregatorName }, 'HTTP quote not implemented yet');
    return {
      amount_out_tokens: '0',
      amount_out_wei: 0n,
      route_summary: null,
      fee_bps: null,
      gas_estimate: null,
      sdk_or_api_version: null,
      latency_ms: 0,
      docs_url: docs.official_docs_url,
      success: false,
      failure_reason: 'http_quote_not_implemented',
    };
  }
}
