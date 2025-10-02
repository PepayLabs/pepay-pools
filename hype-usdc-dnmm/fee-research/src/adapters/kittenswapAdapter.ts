import { BaseAdapter } from './base.js';
import { AdapterDocsMeta, QuoteDirection, QuoteParams, QuoteResult, TokenPair } from '../types.js';
import { findToken } from '../registries/tokens.js';
import { loadDexDocs } from '../registries/dexDocs.js';
import { ethers } from 'ethers';
import { getHyperProvider } from '../utils/provider.js';

const QUOTER_V2_ADDRESS = '0xc58874216AFe47779ADED27B8AAd77E8Bd6eBEBb';
const POOL_ADDRESS = '0x12df9913e9e08453440e3c4b1ae73819160b513e';

const QUOTER_V2_ABI = [
  'function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint160 limitSqrtPrice)) returns (uint256 amountOut,uint256 amountInUsed,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate,uint16 fee)'
];

const POOL_ABI = [
  'function globalState() view returns (uint160 price, int24 tick, uint16 feeZto, uint16 feeOtz, uint16 timepointIndex, uint8 communityFeeToken0, uint8 communityFeeToken1, bool unlocked)',
];

interface PoolState {
  price: bigint;
  feeZto: number;
  feeOtz: number;
}

export class KittenswapAdapter extends BaseAdapter {
  private docsCache: AdapterDocsMeta | null = null;
  private readonly provider = getHyperProvider();
  private readonly quoter = new ethers.Contract(QUOTER_V2_ADDRESS, QUOTER_V2_ABI, this.provider);
  private readonly pool = new ethers.Contract(POOL_ADDRESS, POOL_ABI, this.provider);
  private cachedPoolState: PoolState | null = null;

  override name(): string {
    return 'Kittenswap Finance';
  }

  override integrationKind(): 'dex_adapter' {
    return 'dex_adapter';
  }

  override async docs(): Promise<AdapterDocsMeta> {
    if (this.docsCache) return this.docsCache;
    const docs = await loadDexDocs();
    const entry = docs.find((d) => d.name.toLowerCase() === 'kittenswap finance');
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

  private async loadPoolState(): Promise<PoolState | null> {
    if (this.cachedPoolState) {
      return this.cachedPoolState;
    }
    try {
      const [price, , feeZto, feeOtz] = await this.pool.globalState();
      const state: PoolState = {
        price,
        feeZto,
        feeOtz,
      };
      this.cachedPoolState = state;
      return state;
    } catch (error) {
      return null;
    }
  }

  private async computeMidPrice(tokens: TokenPair): Promise<number | null> {
    const smallAmountIn = ethers.parseUnits('1', tokens.in.decimals);
    try {
      const [amountOutSmall] = await this.quoter.quoteExactInputSingle.staticCall({
        tokenIn: tokens.in.address,
        tokenOut: tokens.out.address,
        amountIn: smallAmountIn,
        limitSqrtPrice: 0n,
      });
      if (amountOutSmall === 0n) {
        return null;
      }
      const amountInTokens = Number(ethers.formatUnits(smallAmountIn, tokens.in.decimals));
      const amountOutTokens = Number(ethers.formatUnits(amountOutSmall, tokens.out.decimals));
      return amountInTokens > 0 ? amountOutTokens / amountInTokens : null;
    } catch (error) {
      const poolState = await this.loadPoolState();
      if (!poolState) return null;
      const { price } = poolState;
      if (!price || price === 0n) return null;
      const priceX192 = price * price;
      const ratio = Number(ethers.formatUnits(priceX192, 192));
      const decimalFactor = Math.pow(10, tokens.in.decimals - tokens.out.decimals);
      return ratio * decimalFactor;
    }
  }

  override async quote(params: QuoteParams): Promise<QuoteResult> {
    const docs = await this.docs();
    const tokens = await this.resolveTokens(params.direction);
    const poolState = await this.loadPoolState();

    try {
      const [amountOutWei, , , , gasEstimateRaw, feeFromQuote] = await this.quoter.quoteExactInputSingle.staticCall({
        tokenIn: tokens.in.address,
        tokenOut: tokens.out.address,
        amountIn: params.amount_in_wei,
        limitSqrtPrice: 0n,
      });

      const amountOutTokens = ethers.formatUnits(amountOutWei, tokens.out.decimals);
      const midPrice = await this.computeMidPrice(tokens);
      const feeFromQuoteNumber = feeFromQuote != null ? Number(feeFromQuote) : null;

      const feeRaw = poolState
        ? params.direction === 'USDC->HYPE'
          ? poolState.feeZto
          : poolState.feeOtz
        : feeFromQuoteNumber;
      const feeBps = typeof feeRaw === 'number' ? feeRaw / 100 : null;

      return {
        amount_out_tokens: amountOutTokens,
        amount_out_wei: amountOutWei,
        route_summary: `Algebra pool ${POOL_ADDRESS}`,
        fee_bps: feeBps,
        gas_estimate: gasEstimateRaw ? BigInt(gasEstimateRaw) : null,
        sdk_or_api_version: 'kittenswap-algebra@1',
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: true,
        mid_price_out_per_in: midPrice,
      };
    } catch (error) {
      return {
        amount_out_tokens: '0',
        amount_out_wei: 0n,
        route_summary: null,
        fee_bps: null,
        gas_estimate: null,
        sdk_or_api_version: 'kittenswap-algebra@1',
        latency_ms: 0,
        docs_url: docs.official_docs_url,
        success: false,
        failure_reason: (error as Error).message,
        mid_price_out_per_in: null,
      };
    }
  }
}
