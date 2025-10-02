import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { findToken } from '../registries/tokens.js';

export class UniswapLikeAdapter extends BaseAdapter {
  private readonly dexName: string;
  private docsCache: AdapterDocsMeta | null = null;

  constructor(dexName: string) {
    super();
    this.dexName = dexName;
  }

  override name(): string {
    return this.dexName;
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((d) => d.name.toLowerCase() === this.dexName.toLowerCase());
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
    return chain_id === 999;
  }

  override async resolveTokens(direction: QuoteDirection): Promise<TokenPair> {
    const chainId = 999;
    const inSymbol = direction === 'USDC->HYPE' ? 'USDC' : 'WHYPE';
    const outSymbol = direction === 'USDC->HYPE' ? 'WHYPE' : 'USDC';
    const tokenIn = await findToken(inSymbol, chainId);
    const tokenOut = await findToken(outSymbol, chainId);
    if (!tokenIn || !tokenOut) {
      throw new Error(`Missing token configuration for ${inSymbol}/${outSymbol}`);
    }
    return { in: tokenIn, out: tokenOut };
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const docs = await this.docs();
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
      failure_reason: 'router_not_discovered',
    };
  }
}
