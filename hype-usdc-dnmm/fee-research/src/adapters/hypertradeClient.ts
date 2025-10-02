import { ethers } from 'ethers';
import { httpRequest } from '../utils/http.js';
import { logger } from '../utils/logger.js';
import { QuoteDirection, QuoteLeg, TokenPair } from '../types.js';
import { performance } from 'perf_hooks';

interface HypertradeQuoteResponse {
  body?: {
    outputAmount?: string;
    fee?: string;
    routeEvm?: HypertradeRoute[];
    error?: string;
  };
  statusCode?: number;
}

interface HypertradeRoute {
  inputTokenAddress: string;
  outputTokenAddress: string;
  splits: HypertradeSplit[];
}

interface HypertradeSplit {
  dex: string;
  portion: number | string;
  fee?: number;
  poolAddress?: string;
}

interface CachedQuote {
  amountInWei: bigint;
  totalOutTokens: string;
  totalOutWei: bigint;
  feeBps: number | null;
  latencyMs: number;
  legs: QuoteLeg[];
  routeSummary: string | null;
}

const BASE_URL = 'https://api.ht.xyz/api/v1';

function normalizeAddress(addr: string): string {
  return addr.toLowerCase();
}

function shortAddress(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function toDecimalStringPortion(portion: number | string): string {
  if (typeof portion === 'number') {
    return portion.toString();
  }
  return portion;
}

function portionToNumber(portion: number | string): number {
  if (typeof portion === 'number') return portion;
  const parsed = Number(portion);
  return Number.isFinite(parsed) ? parsed : 0;
}

function multiplyByDecimal(value: bigint, decimal: string): bigint {
  if (!decimal.includes('.')) {
    return value * BigInt(decimal);
  }
  const [whole, frac] = decimal.split('.');
  const numerator = BigInt((whole === '' ? '0' : whole) + frac);
  const denominator = BigInt(10) ** BigInt(frac.length);
  return (value * numerator) / denominator;
}

export class HypertradeClient {
  private static instance: HypertradeClient | null = null;
  private readonly cache = new Map<string, CachedQuote>();

  static getInstance(): HypertradeClient {
    if (!this.instance) {
      this.instance = new HypertradeClient();
    }
    return this.instance;
  }

  private cacheKey(direction: QuoteDirection, amountInWei: bigint): string {
    return `${direction}|${amountInWei.toString()}`;
  }

  async quote(params: {
    direction: QuoteDirection;
    amountInWei: bigint;
    tokens: TokenPair;
    slippageToleranceBps: number;
  }): Promise<CachedQuote> {
    const key = this.cacheKey(params.direction, params.amountInWei);
    if (this.cache.has(key)) {
      return this.cache.get(key)!;
    }

    const slippagePercent = params.slippageToleranceBps / 100;
    const inputTokenAddress = params.tokens.in.address;
    const outputTokenAddress = params.tokens.out.address;

    const payload = {
      inputAmount: params.amountInWei.toString(),
      slippage: slippagePercent,
      inputTokenAddress,
      outputTokenAddress,
      chainId: params.tokens.in.chain_id,
      enableHyperCore: false,
      userAddress: '0x0000000000000000000000000000000000000000',
    };

    const start = performance.now();
    let response: HypertradeQuoteResponse;
    try {
      response = await httpRequest<HypertradeQuoteResponse>({
        url: `${BASE_URL}/simulation`,
        method: 'POST',
        body: payload,
      });
    } catch (error) {
      logger.error({ direction: params.direction, amount: params.amountInWei.toString(), error }, 'Hypertrade request failed');
      throw error;
    }

    const latencyMs = performance.now() - start;
    const body = response.body;
    if (!body) {
      throw new Error('Hypertrade response malformed (missing body)');
    }
    if (body.error) {
      throw new Error(`Hypertrade error: ${body.error}`);
    }
    if (!body.outputAmount) {
      throw new Error('Hypertrade response missing outputAmount');
    }

    const totalOutTokens = body.outputAmount;
    const totalOutWei = ethers.parseUnits(totalOutTokens, params.tokens.out.decimals);
    const feeBps = body.fee ? Math.round(Number(body.fee) * 10000) : null;

    const routes = body.routeEvm ?? [];
    const finalRoute = routes.find((route) => normalizeAddress(route.outputTokenAddress) === normalizeAddress(outputTokenAddress));
    const legs: QuoteLeg[] = (finalRoute?.splits ?? []).map((split) => {
      const portionStr = toDecimalStringPortion(split.portion ?? 0);
      const amountOutWei = multiplyByDecimal(totalOutWei, portionStr);
      const amountOutTokens = ethers.formatUnits(amountOutWei, params.tokens.out.decimals);
      return {
        dex: split.dex,
        pool_address: split.poolAddress ?? null,
        portion: portionStr,
        fee_bps: typeof split.fee === 'number' ? split.fee : null,
        amount_out_tokens: amountOutTokens,
        amount_out_wei: amountOutWei,
      };
    });

    const routeSummary = routes
      .map((route) => {
        const legsSummary = route.splits
          .map((split) => `${split.dex} (${(portionToNumber(split.portion) * 100).toFixed(0)}%)`)
          .join(' + ');
        return `${shortAddress(route.inputTokenAddress)} -> ${shortAddress(route.outputTokenAddress)} via ${legsSummary}`;
      })
      .join(' | ');

    const cached: CachedQuote = {
      amountInWei: params.amountInWei,
      totalOutTokens,
      totalOutWei,
      feeBps,
      latencyMs,
      legs,
      routeSummary: routeSummary || null,
    };

    this.cache.set(key, cached);
    return cached;
  }
}
