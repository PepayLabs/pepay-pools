import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { findToken } from '../registries/tokens.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { ethers } from 'ethers';
import { getHyperProvider } from '../utils/provider.js';

const QUOTER_ABI = [
  'function quoteExactInputSingle((address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96)) view returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)'
];

const FACTORY_ABI = ['function getPool(address tokenA, address tokenB, uint24 fee) view returns (address)'];

const POOL_ABI = [
  'function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked)',
  'function token0() view returns (address)',
  'function token1() view returns (address)'
];

interface PoolInfo {
  address: string;
  fee: number;
  discoveredViaQuoter: boolean;
}

export interface FactoryQuoterConfig {
  name: string;
  factoryAddress: string;
  quoterAddress: string;
  feeCandidates: number[];
  sdkTag: string;
  docsEntryName?: string;
}

export class UniswapV3FactoryQuoterAdapter extends BaseAdapter {
  private readonly config: FactoryQuoterConfig;
  private docsCache: AdapterDocsMeta | null = null;
  private readonly provider = getHyperProvider();
  private readonly quoter;
  private readonly factory;
  private poolCache: PoolInfo | null = null;

  constructor(config: FactoryQuoterConfig) {
    super();
    this.config = config;
    this.quoter = new ethers.Contract(config.quoterAddress, QUOTER_ABI, this.provider);
    this.factory = new ethers.Contract(config.factoryAddress, FACTORY_ABI, this.provider);
  }

  override name(): string {
    return this.config.name;
  }

  override integrationKind(): 'dex_adapter' {
    return 'dex_adapter';
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const key = (this.config.docsEntryName ?? this.config.name).toLowerCase();
    const entry = docs.find((d) => d.name.toLowerCase() === key);
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
    const tokenInSymbol = direction === 'USDC->HYPE' ? 'USDC' : 'WHYPE';
    const tokenOutSymbol = direction === 'USDC->HYPE' ? 'WHYPE' : 'USDC';
    const tokenIn = await findToken(tokenInSymbol, 999);
    const tokenOut = await findToken(tokenOutSymbol, 999);
    if (!tokenIn || !tokenOut) {
      throw new Error(`Missing token registry entry for ${tokenInSymbol}/${tokenOutSymbol} on HyperEVM`);
    }
    return { in: tokenIn, out: tokenOut };
  }

  private async discoverPool(tokens: TokenPair): Promise<PoolInfo | null> {
    if (this.poolCache) return this.poolCache;
    const tokenA = tokens.in.address;
    const tokenB = tokens.out.address;
    for (const fee of this.config.feeCandidates) {
      const poolAddress: string = await this.factory.getPool(tokenA, tokenB, fee);
      if (poolAddress && poolAddress !== ethers.ZeroAddress) {
        this.poolCache = { address: poolAddress, fee, discoveredViaQuoter: false };
        return this.poolCache;
      }
    }
    return null;
  }

  private async ensurePool(tokens: TokenPair): Promise<PoolInfo | null> {
    const existing = await this.discoverPool(tokens);
    if (existing) return existing;

    const smallAmount = ethers.parseUnits('1', tokens.in.decimals);
    for (const fee of this.config.feeCandidates) {
      try {
        const [amountOut] = await this.quoter.quoteExactInputSingle.staticCall({
          tokenIn: tokens.in.address,
          tokenOut: tokens.out.address,
          fee,
          amountIn: smallAmount,
          sqrtPriceLimitX96: 0n,
        });
        if (amountOut > 0n) {
          const discovered: PoolInfo = {
            address: ethers.ZeroAddress,
            fee,
            discoveredViaQuoter: true,
          };
          this.poolCache = discovered;
          return discovered;
        }
      } catch (error) {
        continue;
      }
    }
    return null;
  }

  private async computeMidPrice(tokens: TokenPair, pool: PoolInfo): Promise<number | null> {
    if (pool.discoveredViaQuoter) {
      const smallAmount = ethers.parseUnits('1', tokens.in.decimals);
      try {
        const [amountOut] = await this.quoter.quoteExactInputSingle.staticCall({
          tokenIn: tokens.in.address,
          tokenOut: tokens.out.address,
          fee: pool.fee,
          amountIn: smallAmount,
          sqrtPriceLimitX96: 0n,
        });
        if (amountOut === 0n) return null;
        const amountInTokens = Number(ethers.formatUnits(smallAmount, tokens.in.decimals));
        const amountOutTokens = Number(ethers.formatUnits(amountOut, tokens.out.decimals));
        return amountInTokens > 0 ? amountOutTokens / amountInTokens : null;
      } catch (error) {
        return null;
      }
    }

    const poolAddress = pool.address;
    if (!poolAddress || poolAddress === ethers.ZeroAddress) {
      return null;
    }
    const contract = new ethers.Contract(poolAddress, POOL_ABI, this.provider);
    try {
      const { sqrtPriceX96 } = await contract.slot0();
      if (!sqrtPriceX96) return null;
      const priceX192 = sqrtPriceX96 * sqrtPriceX96;
      const ratio = Number(ethers.formatUnits(priceX192, 192));
      const token0 = (await contract.token0()).toLowerCase();
      const token1 = (await contract.token1()).toLowerCase();
      const tokenInAddr = tokens.in.address.toLowerCase();
      const tokenOutAddr = tokens.out.address.toLowerCase();
      const decimalFactor = Math.pow(10, tokens.in.decimals - tokens.out.decimals);
      if (tokenInAddr === token0 && tokenOutAddr === token1) {
        return ratio * decimalFactor;
      }
      if (tokenInAddr === token1 && tokenOutAddr === token0) {
        const inverse = ratio * Math.pow(10, tokens.out.decimals - tokens.in.decimals);
        if (inverse === 0) return null;
        return 1 / inverse;
      }
      return ratio * decimalFactor;
    } catch (error) {
      return null;
    }
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const docs = await this.docs();
    const tokens = await this.resolveTokens(params.direction);
    const poolInfo = await this.ensurePool(tokens);

    if (!poolInfo) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: this.config.sdkTag,
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: 'pool_not_found',
        mid_price_out_per_in: null,
      };
    }

    try {
      const [amountOut] = await this.quoter.quoteExactInputSingle.staticCall({
        tokenIn: tokens.in.address,
        tokenOut: tokens.out.address,
        fee: poolInfo.fee,
        amountIn: params.amount_in_wei,
        sqrtPriceLimitX96: 0n,
      });

      const amountOutTokens = ethers.formatUnits(amountOut, tokens.out.decimals);
      const midPrice = await this.computeMidPrice(tokens, poolInfo);
      const summarySegments = [this.config.name, `fee ${(poolInfo.fee / 100).toFixed(2)}%`];
      if (poolInfo.address && poolInfo.address !== ethers.ZeroAddress) {
        summarySegments.push(`pool ${poolInfo.address}`);
      }

      return {
        amount_out_tokens: amountOutTokens,
        amount_out_wei: amountOut,
        route_summary: summarySegments.join(' | '),
        fee_bps: poolInfo.fee / 100,
        gas_estimate: null,
        sdk_or_api_version: this.config.sdkTag,
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: true,
        mid_price_out_per_in: midPrice,
      };
    } catch (error) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary:
          poolInfo.address && poolInfo.address !== ethers.ZeroAddress
            ? `${this.config.name} pool ${poolInfo.address}`
            : `${this.config.name} quoter (fee ${poolInfo.fee / 100}%)`,
        fee_bps: poolInfo.fee / 100,
        gas_estimate: null,
        sdk_or_api_version: this.config.sdkTag,
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: (error as Error).message,
        mid_price_out_per_in: null,
      };
    }
  }
}
