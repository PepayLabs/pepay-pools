import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { findToken } from '../registries/tokens.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { httpRequest } from '../utils/http.js';
import { ethers } from 'ethers';
import { logger } from '../utils/logger.js';

interface HypertradeQuoteResponse {
  body: {
    outputAmount?: string;
    fee?: string;
    action?: string;
    to?: string;
    routeEvm?: Array<{
      inputTokenAddress: string;
      outputTokenAddress: string;
      splits: Array<{
        dex: string;
        portion: number;
        fee?: number;
        poolAddress?: string;
      }>;
    }>;
    error?: string;
  };
  statusCode: number;
}

const CHAIN_ID = 999;
const BASE_URL = 'https://core.ht.xyz/api/v1';
const MID_CACHE_TTL_MS = 5 * 60 * 1000;

interface MidCacheEntry {
  value: number | null;
  cachedAt: number;
}

export class HypertradeAdapter extends BaseAdapter {
  private docsCache: AdapterDocsMeta | null = null;
  private midCache: Map<QuoteDirection, MidCacheEntry> = new Map();

  override name(): string {
    return 'Hypertrade Aggregator';
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((d) => d.name.toLowerCase() === 'hypertrade');
    const meta: AdapterDocsMeta = {
      official_docs_url: entry?.official_docs_url ?? 'https://www.ht.xyz/',
      sdk_package_name: entry?.sdk_package_name ?? null,
      sdk_repo_url: entry?.sdk_repo_url ?? null,
      http_quote_base_url: entry?.http_quote_base_url ?? `${BASE_URL}/trade/getSwapInfo`,
    };
    this.docsCache = meta;
    return meta;
  }

  override async midPrice(direction: QuoteDirection): Promise<number | null> {
    const tokens = await this.resolveTokens(direction);
    return this.getMidPrice(direction, tokens);
  }

  override async supports(chain_id: number): Promise<boolean> {
    return chain_id === CHAIN_ID;
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

  private async requestQuote(inputAmountWei: bigint, tokenIn: string, tokenOut: string, slippageBps: number): Promise<HypertradeQuoteResponse> {
    const payload = {
      inputAmount: inputAmountWei.toString(),
      slippage: slippageBps / 100,
      inputTokenAddress: tokenIn,
      outputTokenAddress: tokenOut,
      enableHyperCore: false,
    };

    const start = performance.now();
    try {
      const response = await httpRequest<HypertradeQuoteResponse>({
        url: `${BASE_URL}/trade/getSwapInfo`,
        method: 'POST',
        body: payload,
      });
      const latency = performance.now() - start;
      if (response.body?.error) {
        throw new Error(response.body.error);
      }
      if (!response.body?.outputAmount) {
        throw new Error('Hypertrade quote missing outputAmount');
      }
      (response as any).latency = latency;
      return response;
    } catch (error) {
      logger.error({ tokenIn, tokenOut, error }, 'Hypertrade quote request failed');
      throw error;
    }
  }

  private routeSummary(routeEvm: HypertradeQuoteResponse['body']['routeEvm']): string | null {
    if (!routeEvm || routeEvm.length === 0) return null;
    return routeEvm
      .map((hop) => {
        const legs = hop.splits
          .map((split) => `${split.dex} (${(split.portion * 100).toFixed(0)}%)`)
          .join(' + ');
        return `${hop.inputTokenAddress.slice(0, 6)}… -> ${hop.outputTokenAddress.slice(0, 6)}… via ${legs}`;
      })
      .join(' | ');
  }

  private async getMidPrice(direction: QuoteDirection, tokens: TokenPair): Promise<number | null> {
    const cached = this.midCache.get(direction);
    const now = Date.now();
    if (cached && now - cached.cachedAt < MID_CACHE_TTL_MS) {
      return cached.value;
    }

    const referenceAmount = direction === 'USDC->HYPE'
      ? ethers.parseUnits('1', tokens.in.decimals)
      : ethers.parseUnits('1', tokens.in.decimals);

    try {
      const response = await this.requestQuote(referenceAmount, tokens.in.address, tokens.out.address, 50);
      const outputAmount = response.body.outputAmount;
      const output = Number(outputAmount);
      if (!Number.isFinite(output) || output <= 0) {
        this.midCache.set(direction, { value: null, cachedAt: now });
        return null;
      }
      const mid = output; // already amount out per 1 unit in because we quoted 1 unit
      this.midCache.set(direction, { value: mid, cachedAt: now });
      return mid;
    } catch (error) {
      logger.warn({ direction, error: (error as Error).message }, 'Failed to compute Hypertrade mid price');
      this.midCache.set(direction, { value: null, cachedAt: now });
      return null;
    }
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const docs = await this.docs();
    const tokens = await this.resolveTokens(params.direction);
    const mid = await this.getMidPrice(params.direction, tokens);

    try {
      const response = await this.requestQuote(params.amount_in_wei, tokens.in.address, tokens.out.address, params.slippage_tolerance_bps);
      const latency = (response as any).latency ?? 0;
      const outputTokens = response.body.outputAmount!;
      const amountOutWei = ethers.parseUnits(outputTokens, tokens.out.decimals);

      const fee = response.body.fee ? Number(response.body.fee) : null;
      const feeBps = fee !== null ? Math.round(fee * 10000) : null;

      return {
        amount_out_tokens: outputTokens,
        amount_out_wei: amountOutWei,
        route_summary: this.routeSummary(response.body.routeEvm) ?? null,
        fee_bps: feeBps,
        gas_estimate: null,
        sdk_or_api_version: 'hypertrade-api@v1',
        latency_ms: latency,
        docs_url: docs.http_quote_base_url ?? docs.official_docs_url,
        success: true,
        mid_price_out_per_in: mid,
      };
    } catch (error) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'hypertrade-api@v1',
        latency_ms: 0,
        docs_url: docs.http_quote_base_url ?? docs.official_docs_url,
        success: false,
        failure_reason: (error as Error).message,
        mid_price_out_per_in: mid,
      };
    }
  }
}
