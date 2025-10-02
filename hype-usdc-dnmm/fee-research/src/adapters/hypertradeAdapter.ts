import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { findToken } from '../registries/tokens.js';
import { HypertradeClient } from './hypertradeClient.js';
import { ethers } from 'ethers';

const CHAIN_ID = 999;
const MID_CACHE_TTL_MS = 5 * 60 * 1000;

interface MidCacheEntry {
  value: number | null;
  cachedAt: number;
}

export class HypertradeAdapter extends BaseAdapter {
  private docsCache: AdapterDocsMeta | null = null;
  private midCache: Map<QuoteDirection, MidCacheEntry> = new Map();
  private readonly client = HypertradeClient.getInstance();

  override name(): string {
    return 'Hypertrade Aggregator';
  }

  override integrationKind(): 'aggregator_http' {
    return 'aggregator_http';
  }

  override async supports(chain_id: number): Promise<boolean> {
    return chain_id === CHAIN_ID;
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((d) => d.name.toLowerCase() === 'hypertrade');
    const meta: AdapterDocsMeta = {
      official_docs_url: entry?.official_docs_url ?? 'https://docs.ht.xyz/api',
      sdk_package_name: entry?.sdk_package_name ?? null,
      sdk_repo_url: entry?.sdk_repo_url ?? null,
      http_quote_base_url: entry?.http_quote_base_url ?? 'https://core.ht.xyz/api/v1/trade/getSwapInfo',
    };
    this.docsCache = meta;
    return meta;
  }

  override async resolveTokens(direction: QuoteDirection): Promise<TokenPair> {
    const tokenInSymbol = direction === 'USDC->HYPE' ? 'USDC' : 'WHYPE';
    const tokenOutSymbol = direction === 'USDC->HYPE' ? 'WHYPE' : 'USDC';
    const tokenIn = await findToken(tokenInSymbol, CHAIN_ID);
    const tokenOut = await findToken(tokenOutSymbol, CHAIN_ID);
    if (!tokenIn || !tokenOut) {
      throw new Error(`Missing token registry entry for ${tokenInSymbol}/${tokenOutSymbol} on chain ${CHAIN_ID}`);
    }
    return { in: tokenIn, out: tokenOut };
  }

  override async midPrice(direction: QuoteDirection): Promise<number | null> {
    const cached = this.midCache.get(direction);
    const now = Date.now();
    if (cached && now - cached.cachedAt < MID_CACHE_TTL_MS) {
      return cached.value;
    }
    const tokens = await this.resolveTokens(direction);
    const amountInWei = direction === 'USDC->HYPE'
      ? ethers.parseUnits('1', tokens.in.decimals)
      : ethers.parseUnits('1', tokens.in.decimals);
    try {
      const quote = await this.client.quote({
        direction,
        amountInWei,
        tokens,
        slippageToleranceBps: 50,
      });
      const amountInTokens = Number(ethers.formatUnits(amountInWei, tokens.in.decimals));
      const amountOutTokens = Number(quote.totalOutTokens);
      const mid = amountInTokens > 0 ? amountOutTokens / amountInTokens : null;
      this.midCache.set(direction, { value: mid, cachedAt: now });
      return mid;
    } catch (error) {
      this.midCache.set(direction, { value: null, cachedAt: now });
      return null;
    }
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const docs = await this.docs();
    const tokens = await this.resolveTokens(params.direction);
    const quote = await this.client.quote({
      direction: params.direction,
      amountInWei: params.amount_in_wei,
      tokens,
      slippageToleranceBps: params.slippage_tolerance_bps,
    });

    const amountOutTokens = quote.totalOutTokens;
    const amountOutWei = quote.totalOutWei;

    const amountInTokens = Number(ethers.formatUnits(params.amount_in_wei, tokens.in.decimals));
    const midPrice = amountInTokens > 0 ? Number(quote.totalOutTokens) / amountInTokens : null;

    return {
      amount_out_tokens: amountOutTokens,
      amount_out_wei: amountOutWei,
      route_summary: quote.routeSummary,
      fee_bps: quote.feeBps,
      gas_estimate: null,
      sdk_or_api_version: 'hypertrade-api@v1',
      latency_ms: quote.latencyMs,
      docs_url: docs.http_quote_base_url ?? docs.official_docs_url,
      success: true,
      mid_price_out_per_in: midPrice,
      legs: quote.legs,
    };
  }
}
