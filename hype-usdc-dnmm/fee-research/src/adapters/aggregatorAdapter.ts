import { BaseAdapter } from './base.js';
import {
  QuoteParams,
  QuoteResult,
  AdapterDocsMeta,
  QuoteDirection,
  TokenPair,
  QuoteLeg,
} from '../types.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { findToken } from '../registries/tokens.js';
import { logger } from '../utils/logger.js';
import { httpRequest } from '../utils/http.js';
import { ethers } from 'ethers';

const SUPPORTED_CHAINS: Record<string, number[]> = {
  '1inch': [1, 56, 137, 42161, 10, 8453, 43114],
  '0x': [1, 56, 137, 42161, 10, 8453],
  Odos: [1, 56, 137, 42161, 10, 8453, 42220],
  ParaSwap: [1, 56, 137, 42161, 10, 8453, 43114],
  Hypertrade: [999],
};

interface HypertradeRouteSplit {
  dex: string;
  portion: number | string;
  fee?: number;
  poolAddress?: string;
}

interface HypertradeRoute {
  inputTokenAddress: string;
  outputTokenAddress: string;
  splits: HypertradeRouteSplit[];
}

interface HypertradeSimulationResponse {
  outputAmount: string;
  fee?: string;
  routeEvm?: HypertradeRoute[];
  error?: string;
}

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

  override integrationKind(): 'aggregator_http' {
    return 'aggregator_http';
  }

  override async supports(chain_id: number): Promise<boolean> {
    const supportedChains = SUPPORTED_CHAINS[this.aggregatorName] ?? [];
    return supportedChains.includes(chain_id);
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
        mid_price_out_per_in: null,
      };
    }

    const supports = await this.supports(params.chain_id);
    if (!supports) {
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
        mid_price_out_per_in: null,
      };
    }

    const tokens = await this.resolveTokens(params.direction);

    const payload = {
      inputAmount: params.amount_in_wei.toString(),
      inputTokenAddress: tokens.in.address,
      outputTokenAddress: tokens.out.address,
      slippage: params.slippage_tolerance_bps / 100,
      enableHyperCore: false,
      chainId: params.chain_id,
      userAddress: '0x0000000000000000000000000000000000000000',
    };

    const start = performance.now();
    let response: HypertradeSimulationResponse;
    try {
      response = await httpRequest<HypertradeSimulationResponse>({
        url: `${docs.http_quote_base_url.replace(/\/$/, '')}`,
        method: 'POST',
        body: payload,
      });
    } catch (error) {
      logger.error({ adapter: this.aggregatorName, error }, 'Hypertrade simulation request failed');
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'hypertrade-api@v1',
        latency_ms: performance.now() - start,
        docs_url: docs.official_docs_url ?? docs.http_quote_base_url,
        success: false,
        failure_reason: (error as Error).message,
        mid_price_out_per_in: null,
      };
    }

    if (response.error) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'hypertrade-api@v1',
        latency_ms: performance.now() - start,
        docs_url: docs.official_docs_url ?? docs.http_quote_base_url,
        success: false,
        failure_reason: response.error,
        mid_price_out_per_in: null,
      };
    }

    const outputAmount = response.outputAmount;
    if (!outputAmount) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'hypertrade-api@v1',
        latency_ms: performance.now() - start,
        docs_url: docs.official_docs_url ?? docs.http_quote_base_url,
        success: false,
        failure_reason: 'hypertrade_missing_output',
        mid_price_out_per_in: null,
      };
    }

    const amountOutWei = BigInt(outputAmount);
    const amountOutTokens = ethers.formatUnits(amountOutWei, tokens.out.decimals);

    const legs: QuoteLeg[] = [];
    const routeSummaryParts: string[] = [];
    for (const route of response.routeEvm ?? []) {
      const hopSummaryParts: string[] = [];
      for (const split of route.splits ?? []) {
        const portion = typeof split.portion === 'number' ? split.portion : Number(split.portion);
        const normalizedPortion = Number.isFinite(portion) ? Math.max(portion, 0) : 0;
        const legOutWei = (amountOutWei * BigInt(Math.round(normalizedPortion * 1_000_000))) / 1_000_000n;
        const legOutTokens = ethers.formatUnits(legOutWei, tokens.out.decimals);
        legs.push({
          dex: split.dex,
          pool_address: split.poolAddress ?? null,
          portion: normalizedPortion.toFixed(6),
          fee_bps: typeof split.fee === 'number' ? split.fee : null,
          amount_out_tokens: legOutTokens,
          amount_out_wei: legOutWei,
        });
        hopSummaryParts.push(`${split.dex} (${(normalizedPortion * 100).toFixed(1)}%)${split.poolAddress ? ` @ ${split.poolAddress}` : ''}`);
      }
      routeSummaryParts.push(`${route.inputTokenAddress} -> ${route.outputTokenAddress} via ${hopSummaryParts.join(' + ')}`);
    }

    const amountInTokens = Number(ethers.formatUnits(params.amount_in_wei, tokens.in.decimals));
    const mid = amountInTokens > 0 ? Number(amountOutTokens) / amountInTokens : null;

    return {
      amount_out_tokens: amountOutTokens,
      amount_out_wei: amountOutWei,
      route_summary: routeSummaryParts.join(' | ') || null,
      fee_bps: null,
      gas_estimate: null,
      sdk_or_api_version: 'hypertrade-api@v1',
      latency_ms: performance.now() - start,
      docs_url: docs.http_quote_base_url ?? docs.official_docs_url,
      success: true,
      mid_price_out_per_in: mid,
      legs,
    };
  }
}
