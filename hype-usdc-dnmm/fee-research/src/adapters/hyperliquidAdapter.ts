import { performance } from 'perf_hooks';
import { ethers } from 'ethers';
import Big from 'big.js';

import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { findToken } from '../registries/tokens.js';
import { HyperliquidClient, HyperliquidOrderBook } from './hyperliquidClient.js';

interface FillResult {
  amountInUsed: Big;
  amountOut: Big;
  averagePrice: Big | null;
  depthUsed: number;
}

interface OrderBookLevel {
  px: string;
  sz: string;
  n: number;
}

function bigFrom(value: string | number | bigint): Big {
  return new Big(value.toString());
}

Big.DP = 40;

export class HyperliquidAdapter extends BaseAdapter {
  private docsCache: AdapterDocsMeta | null = null;
  private readonly client: Pick<HyperliquidClient, 'resolvePairSymbol' | 'fetchOrderBook'>;
  private pairName: string | null = null;

  constructor(client: Pick<HyperliquidClient, 'resolvePairSymbol' | 'fetchOrderBook'> = HyperliquidClient.getInstance()) {
    super();
    this.client = client;
  }

  override name(): string {
    return 'Hyperliquid Spot';
  }

  override integrationKind(): 'http_quote' {
    return 'http_quote';
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((dex) => dex.name.toLowerCase() === 'hyperliquid');
    const meta: AdapterDocsMeta = {
      official_docs_url: entry?.official_docs_url ?? 'https://hyperliquid.gitbook.io/hyperliquid-docs',
      sdk_package_name: entry?.sdk_package_name ?? null,
      sdk_repo_url: entry?.sdk_repo_url ?? null,
      http_quote_base_url: entry?.http_quote_base_url ?? 'https://api.hyperliquid.xyz/info',
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
    const pair = await this.resolvePair();
    const book = await this.client.fetchOrderBook(pair);
    const bestBid = book.bids?.[0];
    const bestAsk = book.asks?.[0];
    if (!bestBid || !bestAsk) return null;

    const bidPx = parseFloat(bestBid.px);
    const askPx = parseFloat(bestAsk.px);
    if (!Number.isFinite(bidPx) || !Number.isFinite(askPx)) return null;

    const mid = (bidPx + askPx) / 2;
    if (direction === 'USDC->HYPE') {
      return mid === 0 ? null : 1 / mid;
    }
    return mid;
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const start = performance.now();
    const docs = await this.docs();
    const tokens = await this.resolveTokens(params.direction);
    const pair = await this.resolvePair();
    const book = await this.client.fetchOrderBook(pair);

    const amountInTokens = bigFrom(ethers.formatUnits(params.amount_in_wei, tokens.in.decimals));

    let fill: FillResult;
    if (params.direction === 'USDC->HYPE') {
      fill = this.fillFromAsks(book, amountInTokens);
    } else {
      fill = this.fillFromBids(book, amountInTokens);
    }

    const latency = performance.now() - start;

    if (fill.amountOut.eq(0)) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: `Hyperliquid order book unavailable (pair ${pair})`,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'hyperliquid-info@v1',
        latency_ms: latency,
        docs_url: docs.http_quote_base_url,
        success: false,
        failure_reason: 'insufficient_liquidity',
        mid_price_out_per_in: null,
      };
    }

    const outDecimals = tokens.out.decimals;
    const amountOutTokensStr = fill.amountOut.toFixed(Math.min(outDecimals, 18));
    const amountOutWei = ethers.parseUnits(amountOutTokensStr, outDecimals);

    const midPrice = await this.midPrice(params.direction);

    const isoTime = new Date(book.timestamp).toISOString();

    return {
      amount_out_tokens: amountOutTokensStr,
      amount_out_wei: amountOutWei,
      route_summary: `Hyperliquid spot order book ${pair} @ ${isoTime} (levels consumed: ${fill.depthUsed})`,
      fee_bps: null,
      gas_estimate: null,
      sdk_or_api_version: 'hyperliquid-info@v1',
      latency_ms: latency,
      docs_url: docs.http_quote_base_url,
      success: true,
      mid_price_out_per_in: midPrice,
    };
  }

  private async resolvePair(): Promise<string> {
    if (this.pairName) return this.pairName;
    this.pairName = await this.client.resolvePairSymbol('HYPE', 'USDC');
    return this.pairName;
  }

  private fillFromAsks(book: HyperliquidOrderBook, amountInUsd: Big): FillResult {
    const asks = book.asks ?? [];
    return this.consumeOrderBook(asks, amountInUsd, 'buy');
  }

  private fillFromBids(book: HyperliquidOrderBook, amountInBase: Big): FillResult {
    const bids = book.bids ?? [];
    return this.consumeOrderBook(bids, amountInBase, 'sell');
  }

  private consumeOrderBook(levels: OrderBookLevel[], amount: Big, mode: 'buy' | 'sell'): FillResult {
    if (levels.length === 0 || amount.lte(0)) {
      return { amountInUsed: new Big(0), amountOut: new Big(0), averagePrice: null, depthUsed: 0 };
    }

    let remaining = amount;
    let outAccum = new Big(0);
    let inAccum = new Big(0);
    let depthUsed = 0;

    for (const level of levels) {
      const price = bigFrom(level.px);
      const size = bigFrom(level.sz);
      if (price.lte(0) || size.lte(0)) continue;

      if (mode === 'buy') {
        const levelCost = size.times(price);
        if (remaining.gte(levelCost)) {
          remaining = remaining.minus(levelCost);
          outAccum = outAccum.plus(size);
          inAccum = inAccum.plus(levelCost);
          depthUsed += 1;
        } else {
          const partialSize = remaining.div(price);
          outAccum = outAccum.plus(partialSize);
          inAccum = inAccum.plus(remaining);
          remaining = new Big(0);
          depthUsed += 1;
          break;
        }
      } else {
        if (remaining.gte(size)) {
          const proceed = size.times(price);
          outAccum = outAccum.plus(proceed);
          inAccum = inAccum.plus(size);
          remaining = remaining.minus(size);
          depthUsed += 1;
        } else {
          const partialProceed = remaining.times(price);
          outAccum = outAccum.plus(partialProceed);
          inAccum = inAccum.plus(remaining);
          remaining = new Big(0);
          depthUsed += 1;
          break;
        }
      }

      if (remaining.lte(0)) {
        break;
      }
    }

    if (remaining.gt(0)) {
      return { amountInUsed: inAccum, amountOut: new Big(0), averagePrice: null, depthUsed };
    }

    const averagePrice = inAccum.eq(0) ? null : outAccum.eq(0) ? null : inAccum.div(outAccum);
    return { amountInUsed: inAccum, amountOut: outAccum, averagePrice, depthUsed };
  }
}
