import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { findToken } from '../registries/tokens.js';
import { HypertradeClient } from './hypertradeClient.js';
import { ethers } from 'ethers';

export class UniswapLikeAdapter extends BaseAdapter {
  private readonly dexName: string;
  private readonly targetDexIds: string[];
  private docsCache: AdapterDocsMeta | null = null;
  private readonly client = HypertradeClient.getInstance();

  constructor(dexName: string, targetDexIds: string[]) {
    super();
    this.dexName = dexName;
    this.targetDexIds = targetDexIds.map((id) => id.toLowerCase());
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

  override async midPrice(direction: QuoteDirection): Promise<number | null> {
    const tokens = await this.resolveTokens(direction);
    const amountInWei = ethers.parseUnits('1', tokens.in.decimals);
    try {
      const quote = await this.client.quote({
        direction,
        amountInWei,
        tokens,
        slippageToleranceBps: 50,
      });
      const amountInTokens = Number(ethers.formatUnits(amountInWei, tokens.in.decimals));
      const amountOutTokens = Number(quote.totalOutTokens);
      return amountInTokens > 0 ? amountOutTokens / amountInTokens : null;
    } catch (_error) {
      return null;
    }
  }

  override integrationKind(): 'aggregator_http' {
    return 'aggregator_http';
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const docs = await this.docs();
    const tokens = await this.resolveTokens(params.direction);
    const hypertradeQuote = await this.client.quote({
      direction: params.direction,
      amountInWei: params.amount_in_wei,
      tokens,
      slippageToleranceBps: params.slippage_tolerance_bps,
    });

    if (!hypertradeQuote.legs || hypertradeQuote.legs.length === 0) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: hypertradeQuote.routeSummary,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'hypertrade-api@v1',
        latency_ms: hypertradeQuote.latencyMs,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: 'hypertrade_missing_legs',
        mid_price_out_per_in: null,
      };
    }

    const matchingLegs = hypertradeQuote.legs.filter((leg) => this.targetDexIds.includes(leg.dex.toLowerCase()));

    if (matchingLegs.length === 0) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: hypertradeQuote.routeSummary,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'hypertrade-api@v1',
        latency_ms: hypertradeQuote.latencyMs,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: 'dex_leg_not_available',
        mid_price_out_per_in: null,
      };
    }

    const amountOutWei = matchingLegs.reduce((acc, leg) => acc + leg.amount_out_wei, 0n);
    const amountOutTokens = ethers.formatUnits(amountOutWei, tokens.out.decimals);
    const feeBps = matchingLegs.find((leg) => leg.fee_bps !== null)?.fee_bps ?? null;
    const amountInTokens = Number(ethers.formatUnits(params.amount_in_wei, tokens.in.decimals));
    const midPrice = amountInTokens > 0 ? Number(amountOutTokens) / amountInTokens : null;
    const routeSummary = matchingLegs
      .map((leg) => {
        const portionPercent = (Number(leg.portion) * 100).toFixed(2);
        const poolRef = leg.pool_address ? ` @ ${leg.pool_address}` : '';
        return `${leg.dex} (${portionPercent}%)${poolRef}`;
      })
      .join(' | ');

    return {
      amount_out_tokens: amountOutTokens,
      amount_out_wei: amountOutWei,
      route_summary: routeSummary || hypertradeQuote.routeSummary,
      fee_bps: feeBps,
      gas_estimate: null,
      sdk_or_api_version: 'hypertrade-api@v1',
      latency_ms: hypertradeQuote.latencyMs,
      docs_url: docs.official_docs_url ?? docs.http_quote_base_url,
      success: true,
      mid_price_out_per_in: midPrice,
      legs: matchingLegs,
    };
  }
}
