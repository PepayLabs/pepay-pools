/**
 * Avalanche USDC/AVAX DEX Quote Aggregator
 *
 * Fetches quotes from multiple DEXs on Avalanche C-Chain for USDC/AVAX pair
 * Calculates slippage and fee bps for trade sizes 1k-50k USDC
 * Exports metrics to CSV for analysis
 */

import { ethers } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';

// ============================================================================
// CONSTANTS & CONFIGURATION
// ============================================================================

const AVALANCHE_RPC = 'https://api.avax.network/ext/bc/C/rpc';
const CHAIN_ID = 43114;

// Token Addresses on Avalanche C-Chain
const TOKENS = {
  USDC: '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E',    // Native USDC
  USDC_E: '0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664',  // Bridged USDC.e
  WAVAX: '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7',   // Wrapped AVAX
};

// Trade sizes to test (in USDC, 6 decimals) - Range: $10 to $100k
const TRADE_SIZES = [
  10,      // $10 USDC
  50,      // $50 USDC
  100,     // $100 USDC
  500,     // $500 USDC
  1000,    // $1k USDC
  5000,    // $5k USDC
  10000,   // $10k USDC
  25000,   // $25k USDC
  50000,   // $50k USDC
  75000,   // $75k USDC
  100000,  // $100k USDC
];

// DEX Configuration
interface DEXConfig {
  name: string;
  enabled: boolean;
  quoter?: string;
  router?: string;
  apiEndpoint?: string;
  fee?: number; // in bps
}

const DEX_CONFIGS: Record<string, DEXConfig> = {
  uniswap: {
    name: 'Uniswap V3',
    enabled: true,
    quoter: '0xbe0F5544EC67e9B3b2D979aaA43f18Fd87E6257F', // QuoterV2
    router: '0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE',
    fee: 30, // 0.3% = 30 bps (can vary by pool)
  },
  woofi: {
    name: 'WOOFi',
    enabled: true,
    router: '0x4c4AF8DBc524681930a27b2F1Af5bcC8062E6fB7', // WooRouterV2 (correct address)
    fee: 0, // WOOFi has dynamic fees, typically very low
  },
  pangolin: {
    name: 'Pangolin',
    enabled: true,
    router: '0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106', // PangolinRouter
    fee: 30, // 0.3% = 30 bps
  },
  dodo: {
    name: 'DODO',
    enabled: true,
    apiEndpoint: 'https://route-api.dodoex.io/dodoroute/quote', // Corrected Smart Route API
    fee: 0, // Dynamic, varies by pool
  },
  dexalot: {
    name: 'Dexalot',
    enabled: false, // Disabled - requires orderbook API implementation
    apiEndpoint: 'https://api.dexalot.com/api',
    fee: 10, // ~0.1% = 10 bps
  },
  balancer: {
    name: 'Balancer V2',
    enabled: false, // Need to verify deployment on Avalanche
    fee: 0,
  },
  thearena: {
    name: 'The Arena',
    enabled: false, // No public API/SDK found
    fee: 100, // Estimated 1% = 100 bps for meme token platforms
  },
  gmx: {
    name: 'GMX',
    enabled: false, // Disabled - requires GMX Vault contract implementation
    router: '0x5F719c2F1095F7B9fc68a68e35B51194f4b6abe8', // GMX Router (needs verification)
    fee: 30, // 0.3% swap fee
  },
  hashflow: {
    name: 'Hashflow',
    enabled: false, // Disabled - HTTP 403 (requires authentication)
    apiEndpoint: 'https://api.hashflow.com/taker/v3',
    fee: 0, // Zero fee (RFQ model)
  },
  cables: {
    name: 'Cables Finance',
    enabled: false, // Hybrid orderbook, need API access
    fee: 0,
  },
};

// ============================================================================
// TYPES & INTERFACES
// ============================================================================

interface QuoteResult {
  dex: string;
  tradeSize: number; // USDC amount in
  amountOut: string; // AVAX amount out (raw)
  amountOutFormatted: string; // AVAX amount out (human readable)
  effectivePrice: string; // USDC per AVAX
  slippageBps: number; // Slippage in basis points vs reference price
  feeBps: number; // Fee in basis points
  gasEstimate?: string;
  timestamp: number;
  error?: string;
}

interface CSVRow {
  dex: string;
  tradeSize: number;
  amountOut: string;
  effectivePrice: string;
  slippageBps: number;
  feeBps: number;
  gasEstimate: string;
  timestamp: string;
  error: string;
}

// ============================================================================
// ABI FRAGMENTS
// ============================================================================

const QUOTER_V2_ABI = [
  'function quoteExactInputSingle((address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96)) external returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)',
];

const WOOFI_ROUTER_ABI = [
  'function querySwap(address fromToken, address toToken, uint256 fromAmount) external view returns (uint256 toAmount)',
];

const PANGOLIN_ROUTER_ABI = [
  'function getAmountsOut(uint256 amountIn, address[] memory path) external view returns (uint256[] memory amounts)',
];

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

function formatAVAX(amount: bigint): string {
  return ethers.formatUnits(amount, 18);
}

function formatUSDC(amount: bigint): string {
  return ethers.formatUnits(amount, 6);
}

function parseUSDC(amount: number): bigint {
  return ethers.parseUnits(amount.toString(), 6);
}

function calculateSlippage(amountOut: bigint, referenceAmountOut: bigint): number {
  if (referenceAmountOut === 0n) return 0;
  const diff = referenceAmountOut - amountOut;
  const slippageBps = Number((diff * 10000n) / referenceAmountOut);
  return slippageBps;
}

function calculateEffectivePrice(usdcIn: bigint, avaxOut: bigint): string {
  if (avaxOut === 0n) return '0';
  // Price = USDC In / AVAX Out
  const usdcInScaled = usdcIn * ethers.parseUnits('1', 18); // Scale up
  const price = usdcInScaled / avaxOut; // Result in 18 decimals
  return ethers.formatUnits(price, 6); // Format as USDC (6 decimals)
}

// ============================================================================
// QUOTE FETCHERS
// ============================================================================

async function getUniswapQuote(
  provider: ethers.Provider,
  amountIn: bigint
): Promise<{ amountOut: bigint; gasEstimate: bigint }> {
  const config = DEX_CONFIGS.uniswap;
  const quoter = new ethers.Contract(config.quoter!, QUOTER_V2_ABI, provider);

  const params = {
    tokenIn: TOKENS.USDC,
    tokenOut: TOKENS.WAVAX,
    amountIn: amountIn,
    fee: 3000, // 0.3% = 3000
    sqrtPriceLimitX96: 0,
  };

  try {
    const result = await quoter.quoteExactInputSingle.staticCall(params);
    return {
      amountOut: result[0],
      gasEstimate: result[3] || 0n,
    };
  } catch (error: any) {
    throw new Error(`Uniswap quote failed: ${error.message}`);
  }
}

async function getWOOFiQuote(
  provider: ethers.Provider,
  amountIn: bigint
): Promise<{ amountOut: bigint }> {
  const config = DEX_CONFIGS.woofi;
  const router = new ethers.Contract(config.router!, WOOFI_ROUTER_ABI, provider);

  try {
    const amountOut = await router.querySwap(TOKENS.USDC, TOKENS.WAVAX, amountIn);
    return { amountOut };
  } catch (error: any) {
    throw new Error(`WOOFi quote failed: ${error.message}`);
  }
}

async function getPangolinQuote(
  provider: ethers.Provider,
  amountIn: bigint
): Promise<{ amountOut: bigint }> {
  const config = DEX_CONFIGS.pangolin;
  const router = new ethers.Contract(config.router!, PANGOLIN_ROUTER_ABI, provider);

  try {
    const path = [TOKENS.USDC, TOKENS.WAVAX];
    const amounts = await router.getAmountsOut(amountIn, path);
    return { amountOut: amounts[1] };
  } catch (error: any) {
    throw new Error(`Pangolin quote failed: ${error.message}`);
  }
}

async function getDODOQuote(
  amountIn: bigint
): Promise<{ amountOut: bigint }> {
  // DODO Smart Route API
  const config = DEX_CONFIGS.dodo;
  const url = `${config.apiEndpoint}?chainId=${CHAIN_ID}&fromTokenAddress=${TOKENS.USDC}&toTokenAddress=${TOKENS.WAVAX}&fromAmount=${amountIn.toString()}&slippage=1&rpc=https://api.avax.network/ext/bc/C/rpc`;

  try {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    const data: any = await response.json();
    // Try different possible response formats
    const amountOut = BigInt(data.resAmount || data.toAmount || data.targetAmount || '0');
    return { amountOut };
  } catch (error: any) {
    throw new Error(`DODO quote failed: ${error.message}`);
  }
}

async function getHashflowQuote(
  amountIn: bigint
): Promise<{ amountOut: bigint }> {
  // Hashflow RFQ API
  const config = DEX_CONFIGS.hashflow;

  try {
    // Step 1: Get price levels
    const priceLevelsUrl = `${config.apiEndpoint}/price-levels?chainId=${CHAIN_ID}&baseToken=${TOKENS.USDC}&quoteToken=${TOKENS.WAVAX}`;
    const priceResponse = await fetch(priceLevelsUrl);

    if (!priceResponse.ok) {
      throw new Error(`Price levels HTTP ${priceResponse.status}`);
    }

    const priceData = await priceResponse.json();

    // Step 2: Request RFQ
    const rfqUrl = `${config.apiEndpoint}/rfq`;
    const rfqBody = {
      chainId: CHAIN_ID,
      baseToken: TOKENS.USDC,
      quoteToken: TOKENS.WAVAX,
      baseTokenAmount: amountIn.toString(),
      trader: '0x0000000000000000000000000000000000000000', // Dummy address for quote
    };

    const rfqResponse = await fetch(rfqUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(rfqBody),
    });

    if (!rfqResponse.ok) {
      throw new Error(`RFQ HTTP ${rfqResponse.status}`);
    }

    const rfqData: any = await rfqResponse.json();
    const amountOut = BigInt(rfqData.quoteTokenAmount || '0');
    return { amountOut };
  } catch (error: any) {
    throw new Error(`Hashflow quote failed: ${error.message}`);
  }
}

async function getGMXQuote(
  provider: ethers.Provider,
  amountIn: bigint
): Promise<{ amountOut: bigint }> {
  // GMX uses a different model - this is a placeholder
  // Would need the actual GMX vault/reader contract
  throw new Error('GMX quote implementation pending - requires GMX Vault contract');
}

async function getDexalotQuote(
  amountIn: bigint
): Promise<{ amountOut: bigint }> {
  // Dexalot uses an orderbook - would need WebSocket connection
  throw new Error('Dexalot quote implementation pending - requires orderbook API');
}

// ============================================================================
// MAIN QUOTE AGGREGATION
// ============================================================================

async function fetchQuote(
  dexName: string,
  provider: ethers.Provider,
  amountIn: bigint,
  referenceAmountOut: bigint
): Promise<QuoteResult> {
  const config = DEX_CONFIGS[dexName];
  const timestamp = Date.now();

  const baseResult: QuoteResult = {
    dex: config.name,
    tradeSize: Number(formatUSDC(amountIn)),
    amountOut: '0',
    amountOutFormatted: '0',
    effectivePrice: '0',
    slippageBps: 0,
    feeBps: config.fee || 0,
    timestamp,
  };

  if (!config.enabled) {
    return {
      ...baseResult,
      error: 'DEX not enabled',
    };
  }

  try {
    let amountOut: bigint;
    let gasEstimate: bigint = 0n;

    switch (dexName) {
      case 'uniswap': {
        const result = await getUniswapQuote(provider, amountIn);
        amountOut = result.amountOut;
        gasEstimate = result.gasEstimate;
        break;
      }
      case 'woofi': {
        const result = await getWOOFiQuote(provider, amountIn);
        amountOut = result.amountOut;
        break;
      }
      case 'pangolin': {
        const result = await getPangolinQuote(provider, amountIn);
        amountOut = result.amountOut;
        break;
      }
      case 'dodo': {
        const result = await getDODOQuote(amountIn);
        amountOut = result.amountOut;
        break;
      }
      case 'hashflow': {
        const result = await getHashflowQuote(amountIn);
        amountOut = result.amountOut;
        break;
      }
      case 'gmx': {
        const result = await getGMXQuote(provider, amountIn);
        amountOut = result.amountOut;
        break;
      }
      case 'dexalot': {
        const result = await getDexalotQuote(amountIn);
        amountOut = result.amountOut;
        break;
      }
      default:
        throw new Error(`Unknown DEX: ${dexName}`);
    }

    const slippageBps = calculateSlippage(amountOut, referenceAmountOut);
    const effectivePrice = calculateEffectivePrice(amountIn, amountOut);

    return {
      ...baseResult,
      amountOut: amountOut.toString(),
      amountOutFormatted: formatAVAX(amountOut),
      effectivePrice,
      slippageBps,
      gasEstimate: gasEstimate.toString(),
    };
  } catch (error: any) {
    return {
      ...baseResult,
      error: error.message,
    };
  }
}

async function aggregateQuotes(
  provider: ethers.Provider
): Promise<QuoteResult[]> {
  const results: QuoteResult[] = [];

  for (const tradeSize of TRADE_SIZES) {
    const amountIn = parseUSDC(tradeSize);
    console.log(`\n=== Fetching quotes for ${tradeSize} USDC ===`);

    // Get reference quote from Uniswap (most liquid)
    let referenceAmountOut = 0n;
    try {
      const uniResult = await getUniswapQuote(provider, amountIn);
      referenceAmountOut = uniResult.amountOut;
      console.log(`Reference (Uniswap): ${formatAVAX(referenceAmountOut)} AVAX`);
    } catch (error: any) {
      console.error(`Failed to get reference quote: ${error.message}`);
    }

    // Fetch quotes from all DEXs
    for (const dexName of Object.keys(DEX_CONFIGS)) {
      const result = await fetchQuote(dexName, provider, amountIn, referenceAmountOut);
      results.push(result);

      if (result.error) {
        console.log(`${result.dex}: ERROR - ${result.error}`);
      } else {
        console.log(
          `${result.dex}: ${result.amountOutFormatted} AVAX ` +
          `(${result.effectivePrice} USDC/AVAX, ` +
          `slippage: ${result.slippageBps}bps, ` +
          `fee: ${result.feeBps}bps)`
        );
      }
    }
  }

  return results;
}

// ============================================================================
// CSV EXPORT
// ============================================================================

function exportToCSV(results: QuoteResult[], filename: string): void {
  const csvRows: CSVRow[] = results.map(r => ({
    dex: r.dex,
    tradeSize: r.tradeSize,
    amountOut: r.amountOutFormatted,
    effectivePrice: r.effectivePrice,
    slippageBps: r.slippageBps,
    feeBps: r.feeBps,
    gasEstimate: r.gasEstimate || '',
    timestamp: new Date(r.timestamp).toISOString(),
    error: r.error || '',
  }));

  const headers = [
    'dex',
    'tradeSize',
    'amountOut',
    'effectivePrice',
    'slippageBps',
    'feeBps',
    'gasEstimate',
    'timestamp',
    'error',
  ];

  const csvContent = [
    headers.join(','),
    ...csvRows.map(row =>
      headers.map(h => {
        const value = row[h as keyof CSVRow];
        // Escape commas and quotes
        if (typeof value === 'string' && (value.includes(',') || value.includes('"'))) {
          return `"${value.replace(/"/g, '""')}"`;
        }
        return value;
      }).join(',')
    ),
  ].join('\n');

  const metricsDir = path.join(__dirname, 'metrics');
  if (!fs.existsSync(metricsDir)) {
    fs.mkdirSync(metricsDir, { recursive: true });
  }

  const filepath = path.join(metricsDir, filename);
  fs.writeFileSync(filepath, csvContent, 'utf-8');
  console.log(`\nCSV exported to: ${filepath}`);
}

// ============================================================================
// MAIN EXECUTION
// ============================================================================

async function main() {
  console.log('Avalanche USDC/AVAX DEX Quote Aggregator');
  console.log('='.repeat(50));
  console.log(`RPC: ${AVALANCHE_RPC}`);
  console.log(`USDC: ${TOKENS.USDC}`);
  console.log(`WAVAX: ${TOKENS.WAVAX}`);
  console.log(`Trade Sizes: ${TRADE_SIZES.join(', ')} USDC`);
  console.log('='.repeat(50));

  const provider = new ethers.JsonRpcProvider(AVALANCHE_RPC);

  // Verify connection
  try {
    const network = await provider.getNetwork();
    console.log(`Connected to Avalanche C-Chain (chainId: ${network.chainId})`);
  } catch (error) {
    console.error('Failed to connect to Avalanche RPC');
    process.exit(1);
  }

  // Aggregate quotes
  const results = await aggregateQuotes(provider);

  // Export to CSV
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-').split('T')[0];
  const filename = `avax_metrics_${timestamp}.csv`;
  exportToCSV(results, filename);

  // Print summary
  console.log('\nSummary:');
  const successful = results.filter(r => !r.error).length;
  const failed = results.filter(r => r.error).length;
  console.log(`Total quotes: ${results.length}`);
  console.log(`Successful: ${successful}`);
  console.log(`Failed: ${failed}`);

  console.log('\nDone!');
}

// Run if called directly
if (require.main === module) {
  main().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}

export { main, aggregateQuotes, fetchQuote, exportToCSV };
export type { QuoteResult };
