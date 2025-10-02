import { QuoteParams, QuoteResult, AdapterDocsMeta, QuoteDirection, TokenPair } from '../types.js';

export abstract class BaseAdapter {
  abstract name(): string;
  abstract supports(chain_id: number): Promise<boolean>;
  abstract resolveTokens(direction: QuoteDirection): Promise<TokenPair>;
  abstract docs(): Promise<AdapterDocsMeta>;

  async quote(_params: QuoteParams): Promise<QuoteResult> {
    return {
      amount_out_tokens: '0',
      amount_out_wei: 0n,
      route_summary: null,
      fee_bps: null,
      gas_estimate: null,
      sdk_or_api_version: null,
      latency_ms: 0,
      docs_url: (await this.docs()).official_docs_url,
      success: false,
      failure_reason: 'quote_not_implemented',
    };
  }
}
