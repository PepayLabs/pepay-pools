import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { findToken } from '../registries/tokens.js';

export class CurveAdapter extends BaseAdapter {
  private docsCache: AdapterDocsMeta | null = null;

  override name(): string {
    return 'Curve Finance';
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((d) => d.name === 'Curve Finance');
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
    return [1, 10, 56, 137, 42161, 43114, 999].includes(chain_id);
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
      sdk_or_api_version: docs.sdk_package_name,
      latency_ms: 0,
      docs_url: docs.official_docs_url,
      success: false,
      failure_reason: 'curve_adapter_not_configured_for_hype',
    };
  }
}
