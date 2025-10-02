import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { findToken } from '../registries/tokens.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { ethers } from 'ethers';
import { getHyperProvider } from '../utils/provider.js';

const QUOTER_V2_ADDRESS = '0x03A918020f47d650b70138CF564e154C7923C97F';
const FACTORY_ADDRESS = '0xB1c0fa0B789320044A6F623cFe5eBda9562602E3';
const FEE_CANDIDATES: number[] = [100, 300, 500, 1000, 3000, 10000];

const QUOTER_V2_ABI = [
  'function quoteExactInputSingle((address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96)) returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed)'
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
}

export class HyperswapAdapter extends BaseAdapter {
  private docsCache: AdapterDocsMeta | null = null;
  private readonly provider = getHyperProvider();
  private readonly quoter = new ethers.Contract(QUOTER_V2_ADDRESS, QUOTER_V2_ABI, this.provider);
  private readonly factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, this.provider);
  private poolCache: PoolInfo | null = null;

  override name(): string {
    return 'HyperSwap';
  }

  override integrationKind(): 'dex_adapter' {
    return 'dex_adapter';
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((d) => d.name.toLowerCase() === 'hyperswap');
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
    for (const fee of FEE_CANDIDATES) {
      const poolAddress: string = await this.factory.getPool(tokenA, tokenB, fee);
      if (poolAddress && poolAddress !== ethers.ZeroAddress) {
        this.poolCache = { address: poolAddress, fee };
        return this.poolCache;
      }
    }
    return null;
  }

  private async computeMidPrice(tokens: TokenPair, poolInfo: PoolInfo): Promise<number | null> {
    const pool = new ethers.Contract(poolInfo.address, POOL_ABI, this.provider);
    try {
      const { sqrtPriceX96 } = await pool.slot0();
      if (!sqrtPriceX96) return null;
      const priceX192 = sqrtPriceX96 * sqrtPriceX96;
      const ratio = Number(ethers.formatUnits(priceX192, 192));

      const token0 = (await pool.token0()).toLowerCase();
      const token1 = (await pool.token1()).toLowerCase();
      const tokenInAddress = tokens.in.address.toLowerCase();
      const tokenOutAddress = tokens.out.address.toLowerCase();

      const decimalFactor = Math.pow(10, tokens.in.decimals - tokens.out.decimals);
      if (tokenInAddress === token0 && tokenOutAddress === token1) {
        return ratio * decimalFactor;
      }
      if (tokenInAddress === token1 && tokenOutAddress === token0) {
        const inverse = ratio * Math.pow(10, tokens.out.decimals - tokens.in.decimals);
        if (inverse === 0) return null;
        return 1 / inverse;
      }
      return ratio * decimalFactor;
    } catch (error) {
      return null;
    }
  }

  private async quoteSmall(tokens: TokenPair, poolInfo: PoolInfo): Promise<number | null> {
    const smallAmount = ethers.parseUnits('1', tokens.in.decimals);
    try {
      const [amountOut] = await this.quoter.quoteExactInputSingle.staticCall({
        tokenIn: tokens.in.address,
        tokenOut: tokens.out.address,
        fee: poolInfo.fee,
        amountIn: smallAmount,
        sqrtPriceLimitX96: 0n,
      });
      if (amountOut === 0n) return null;
      const inTokens = Number(ethers.formatUnits(smallAmount, tokens.in.decimals));
      const outTokens = Number(ethers.formatUnits(amountOut, tokens.out.decimals));
      return inTokens > 0 ? outTokens / inTokens : null;
    } catch (error) {
      return null;
    }
  }

  private async ensurePool(tokens: TokenPair): Promise<PoolInfo | null> {
    let pool = await this.discoverPool(tokens);
    if (pool) return pool;

    const smallAmount = ethers.parseUnits('1', tokens.in.decimals);
    for (const fee of FEE_CANDIDATES) {
      try {
        const [amountOut] = await this.quoter.quoteExactInputSingle.staticCall({
          tokenIn: tokens.in.address,
          tokenOut: tokens.out.address,
          fee,
          amountIn: smallAmount,
          sqrtPriceLimitX96: 0n,
        });
        if (amountOut > 0n) {
          pool = { address: ethers.ZeroAddress, fee };
          this.poolCache = pool;
          return pool;
        }
      } catch (error) {
        continue;
      }
    }
    return null;
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
        sdk_or_api_version: 'hyperswap-v3@1',
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
      let midPrice = await this.quoteSmall(tokens, poolInfo);
      if (!midPrice) {
        midPrice = await this.computeMidPrice(tokens, poolInfo);
      }

      const feeBps = poolInfo.fee / 100;

      return {
        amount_out_tokens: amountOutTokens,
        amount_out_wei: amountOut,
        route_summary: `HyperSwap pool ${poolInfo.address} (fee ${feeBps / 100}%)`,
        fee_bps: feeBps,
        gas_estimate: null,
        sdk_or_api_version: 'hyperswap-v3@1',
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: true,
        mid_price_out_per_in: midPrice,
      };
    } catch (error) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: poolInfo.address === ethers.ZeroAddress ? 'HyperSwap quoter (pool discovery)' : `HyperSwap pool ${poolInfo.address}`,
        fee_bps: poolInfo.fee / 100,
        gas_estimate: null,
        sdk_or_api_version: 'hyperswap-v3@1',
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: (error as Error).message,
        mid_price_out_per_in: null,
      };
    }
  }
}
