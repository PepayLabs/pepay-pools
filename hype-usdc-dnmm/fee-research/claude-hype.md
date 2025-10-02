# HyperEVM Fee Research Documentation

## Overview

This document covers the HyperEVM HYPE/USDC DEX quote aggregation implementation. The script fetches real-time swap quotes from multiple DEXs on HyperEVM, calculates slippage and fees for various trade sizes, and exports data to CSV for analysis.

## HyperEVM Implementation (evaluate_hype.ts)

### Network Configuration

**HyperEVM Mainnet**
- **Chain ID**: 999
- **RPC URL**: https://rpc.hyperliquid.xyz/evm
- **Block Explorer**: https://hyperevmscan.io
- **Rate Limit**: 100 requests/minute/IP
- **RPC Type**: Read-only (supports `eth_call`, `eth_getLogs`, `eth_blockNumber` only)

**Testnet**
- **Chain ID**: 998
- **RPC URL**: https://rpc.hyperliquid-testnet.xyz/evm

### Token Addresses

```typescript
WHYPE (Wrapped HYPE): 0x5555555555555555555555555555555555555555
USDC (Native):        0xb88339CB7199b77E23DB6E890353E22632Ba630f
```

**Important**: HYPE is the native gas token on HyperEVM. It must be wrapped to WHYPE (ERC-20) for DEX interactions, similar to how ETH is wrapped to WETH on Ethereum.

### Trade Sizes

The script tests the following USDC amounts:

```typescript
[1000, 5000, 10000, 25000, 50000] // USDC (6 decimals)
```

These sizes help analyze:
- **1k-5k**: Retail trade behavior
- **10k-25k**: Larger retail / small institutional
- **50k**: Price impact and liquidity depth

### Supported DEXs

| DEX | Status | Integration Method | Fee Structure | Notes |
|-----|--------|-------------------|---------------|-------|
| **Hyperliquid Native** | ❌ Not Applicable | L1 Orderbook API | 0.025% (2.5 bps) | L1 orderbook, not EVM-based |
| **Project X** | ⏳ Pending | Uniswap V2 Router | 0% (0 bps) | Contract addresses not documented |
| **Hybra Finance** | ⏳ Pending | Uniswap V3 Quoter | 0.25% (25 bps) | Uses Uniswap V3 architecture |
| **HyperSwap** | ⏳ Pending | Uniswap V2 Router | 0.3% (30 bps) | First native DEX on HyperEVM |
| **Upheaval Finance** | ⏳ Pending | Uniswap V3 Quoter | 0.1% (10 bps) | V3 concentrated liquidity |
| **Kittenswap** | ⏳ Pending | Uniswap V2 Router | 0.3% (30 bps) | Community-owned metadex |
| **Gliquid** | ⏳ Pending | Uniswap V3 Quoter | 0.05% (5 bps) | Multiple pools available |
| **Curve Finance** | ⏳ Pending | Curve API | 0.04% (4 bps) | Verify deployment on HyperEVM |
| **Drip.Trade** | ❌ Not Applicable | NFT Exchange | N/A | NFT exchange, not for token swaps |
| **HyperBrick** | ⏳ Pending | Liquidity Book Router | Variable | Liquidity Book model |
| **HX Finance** | ⏳ Pending | Uniswap V2 Router | 0.3% (30 bps est.) | Privacy-focused DeFi |

### Known Contract Addresses

**Status**: Most HyperEVM DEXs are newly deployed (early 2025) and contract addresses are not yet publicly documented.

```typescript
// Upheaval Finance
Position Manager: 0xc8352a2eba29f4d9bd4221c07d3461bacc779088

// HyperSwap
// Check docs.hyperswap.exchange for V2/V3 deployment addresses

// Hybra Finance
// Multiple pools found on GeckoTerminal
// Check hybra.finance for router/quoter addresses

// Project X
// Check prjx.com or HyperEVMScan for contract addresses

// Gliquid
// Pool addresses available via GeckoTerminal
// Need main router/quoter contracts

// HyperBrick
// Check hyperbrick.xyz for Liquidity Book router

// Kittenswap
// Check kittenswap.finance for router addresses

// HX Finance
// Check hx.finance for contract addresses
```

## Integration Challenges

### 1. New Ecosystem
HyperEVM mainnet launched recently. Many protocols are still in early deployment stages with limited public documentation.

### 2. Limited Documentation
Most DEXs don't have publicly available developer documentation or published contract addresses yet.

### 3. Contract Discovery
Need to manually find verified contracts on HyperEVMScan or contact DEX teams directly for addresses.

### 4. No Native SDKs
Unlike mature chains, most HyperEVM DEXs don't have published TypeScript/JavaScript SDKs yet. Must use generic ethers.js with contract ABIs.

### 5. RPC Limitations
- Read-only RPC endpoint
- 100 requests/minute rate limit per IP
- Cannot submit transactions via public RPC
- Limited to `eth_call`, `eth_getLogs`, `eth_blockNumber` methods

### 6. HYPE Wrapping Requirement
Native HYPE must be wrapped to WHYPE (0x5555...5555) for ERC-20 interactions in smart contracts.

## Research Findings

### Well-Documented Protocols

**Hyperliquid Native**
- Has comprehensive Python SDK for L1 orderbook
- API docs available at hyperliquid.gitbook.io
- Not applicable for EVM-based swaps (different architecture)

**HyperSwap**
- Documentation site at docs.hyperswap.exchange
- API docs at docs.hyperswap.ai
- Deployment addresses section exists but needs verification

**Hybra Finance**
- Based on Uniswap V3 architecture (unmodified contracts)
- Uses concentrated liquidity pools
- Pool data available on GeckoTerminal and DEX Screener

### Limited Public Access

**Project X**
- Active DEX with significant volume ($167.73m TVL)
- Website at prjx.com claims "0% fees"
- No public contract addresses or developer docs found
- Created by pseudonymous developers @Lamboland_ and @BOBBYBIGYIELD

**Kittenswap**
- Community-owned metadex
- Website at kittenswap.finance
- Contract addresses not prominently published
- Active on HyperEVM with volume

**Upheaval Finance**
- V3 concentrated liquidity DEX
- Position manager found: 0xc8352a2eba29f4d9bd4221c07d3461bacc779088
- Need quoter and router addresses
- Website at upheaval.fi

**Gliquid**
- Multiple pools found on GeckoTerminal
- Pool contract addresses available
- Main router/quoter contracts not documented
- Estimated $1.44m TVL

**HX Finance**
- Privacy-focused DeFi platform
- Website at hx.finance claims "future of private DeFi"
- Early stage, limited public information
- No published contract addresses

**HyperBrick**
- Uses Liquidity Book model (similar to Trader Joe V2)
- Website at hyperbrick.xyz
- Need LB router contract address
- Fee structure varies by bin (not fixed)

**Curve Finance**
- 11 chains deployment claimed
- Need to verify actual deployment on HyperEVM
- If deployed, would use Curve's stableswap algorithm

### Not Applicable

**Hyperliquid Native DEX**
- L1 orderbook (HyperCore), not EVM-based
- Requires WebSocket/REST API approach, not contract calls
- Different architecture from HyperEVM DEXs
- 0.025% maker/taker fees

**Drip.Trade**
- NFT exchange platform
- Not applicable for fungible token (HYPE/USDC) swaps
- Website at drip.trade

## Implementation Architecture

### Script Structure

```typescript
// 1. Configuration Layer
const TOKENS = { WHYPE: '0x555...', USDC: '0xb88...' };
const DEX_CONFIGS = { /* 11 DEX configurations */ };

// 2. Quote Fetchers (by DEX type)
getUniswapV2Quote()  // For V2 clones
getUniswapV3Quote()  // For V3 clones
// Add API/orderbook fetchers as needed

// 3. Aggregation Engine
aggregateQuotes()  // Fetches from all enabled DEXs

// 4. Metrics Calculator
calculateSlippage()
calculateEffectivePrice()

// 5. CSV Exporter
exportToCSV()  // Saves to metrics/hype_metrics_*.csv
```

### Integration Patterns

#### Uniswap V2 Clone Integration

```typescript
async function getUniswapV2Quote(
  provider: ethers.Provider,
  routerAddress: string,
  amountIn: bigint
): Promise<{ amountOut: bigint }> {
  const router = new ethers.Contract(
    routerAddress,
    UNISWAP_V2_ROUTER_ABI,
    provider
  );

  const path = [TOKENS.USDC, TOKENS.WHYPE];
  const amounts = await router.getAmountsOut(amountIn, path);
  return { amountOut: amounts[1] };
}
```

**Works for**: Project X, HyperSwap, Kittenswap, HX Finance

#### Uniswap V3 Clone Integration

```typescript
async function getUniswapV3Quote(
  provider: ethers.Provider,
  quoterAddress: string,
  amountIn: bigint,
  fee: number = 3000
): Promise<{ amountOut: bigint; gasEstimate: bigint }> {
  const quoter = new ethers.Contract(
    quoterAddress,
    UNISWAP_V3_QUOTER_ABI,
    provider
  );

  const params = {
    tokenIn: TOKENS.USDC,
    tokenOut: TOKENS.WHYPE,
    amountIn: amountIn,
    fee: fee,  // 500, 3000, or 10000
    sqrtPriceLimitX96: 0,
  };

  const result = await quoter.quoteExactInputSingle.staticCall(params);
  return {
    amountOut: result[0],
    gasEstimate: result[3],
  };
}
```

**Works for**: Hybra Finance, Upheaval Finance, Gliquid

## How to Enable a DEX

Once you obtain contract addresses (via HyperEVMScan, DEX docs, or community channels):

### Step 1: Update DEX_CONFIGS

```typescript
// In evaluate_hype.ts
const DEX_CONFIGS: Record<string, DEXConfig> = {
  hyperswap: {
    name: 'HyperSwap',
    enabled: true,  // ← Change from false to true
    type: 'uniswap-v2',
    router: '0x...YOUR_ROUTER_ADDRESS...',  // ← Add address
    fee: 30, // 0.3% = 30 bps
  },

  hybra: {
    name: 'Hybra Finance',
    enabled: true,  // ← Change from false to true
    type: 'uniswap-v3',
    quoter: '0x...YOUR_QUOTER_ADDRESS...',  // ← Add address
    fee: 25, // 0.25% = 25 bps
  },
};
```

### Step 2: Run the Script

```bash
npx ts-node hype-usdc-dnmm/fee-research/evaluate_hype.ts
```

### Step 3: Verify Output

The script will:
1. Connect to HyperEVM RPC
2. Fetch quotes for all enabled DEXs
3. Calculate slippage vs best quote
4. Export to `metrics/hype_metrics_YYYY-MM-DD.csv`

## Metrics Calculated

### Effective Price

```typescript
effectivePrice = (USDC In / HYPE Out) * (10^18 / 10^6)
```

Example: 1000 USDC → 50 HYPE
Effective Price = 1000 / 50 = 20 USDC per HYPE

### Slippage (Basis Points)

```typescript
slippageBps = ((referenceAmountOut - actualAmountOut) / referenceAmountOut) * 10000
```

Example:
- Reference (best DEX): 50 HYPE
- Actual (DEX X): 49.5 HYPE
- Slippage = ((50 - 49.5) / 50) * 10000 = 100 bps (1%)

### Fee (Basis Points)

Protocol fee charged by the DEX:
- 1 bp = 0.01%
- 10 bps = 0.1%
- 30 bps = 0.3%
- 100 bps = 1%

## CSV Output Format

```csv
dex,tradeSize,amountOut,effectivePrice,slippageBps,feeBps,gasEstimate,timestamp,error
HyperSwap,1000,50.123456,19.95,0,30,185000,2025-10-02T10:30:00Z,
Hybra Finance,1000,50.234567,19.91,22,25,220000,2025-10-02T10:30:01Z,
Project X,1000,50.345678,19.87,44,0,150000,2025-10-02T10:30:02Z,
...
```

### Column Descriptions

- **dex**: DEX name
- **tradeSize**: Input amount in USDC
- **amountOut**: Output amount in HYPE (formatted with decimals)
- **effectivePrice**: USDC per HYPE
- **slippageBps**: Slippage vs reference in basis points
- **feeBps**: Protocol fee in basis points
- **gasEstimate**: Estimated gas units (if available)
- **timestamp**: ISO 8601 timestamp
- **error**: Error message if quote failed (empty if successful)

## Usage

### Running the Script

```bash
# From project root
npx ts-node hype-usdc-dnmm/fee-research/evaluate_hype.ts

# Output location
# hype-usdc-dnmm/fee-research/metrics/hype_metrics_YYYY-MM-DD.csv
```

### Programmatic Usage

```typescript
import { aggregateQuotes, exportToCSV } from './evaluate_hype';
import { ethers } from 'ethers';

const provider = new ethers.JsonRpcProvider('https://rpc.hyperliquid.xyz/evm');
const results = await aggregateQuotes(provider);
exportToCSV(results, 'custom_metrics.csv');
```

## Next Steps for Full Implementation

### 1. Monitor HyperEVMScan
Visit https://hyperevmscan.io/contractsVerified regularly to find newly verified DEX contracts.

### 2. Contact DEX Teams
Reach out via official channels for developer documentation:
- **HyperSwap**: Twitter @HyperSwapX
- **Project X**: Twitter @prjx_hl
- **Hybra Finance**: Twitter @HybraFinance
- **Upheaval**: Twitter @Upheavalfi
- **Kittenswap**: Check kittenswap.finance
- **Gliquid**: Check community channels
- **HyperBrick**: Check hyperbrick.xyz
- **HX Finance**: Check hx.finance

### 3. Join Community Channels
- Hyperliquid Discord: Primary source for ecosystem updates
- Telegram groups: Often share contract addresses
- Developer forums: Check for integration guides

### 4. Test Incrementally
- Enable DEXs one at a time as addresses become available
- Verify quotes against DEX UI before trusting data
- Start with small trade sizes to validate accuracy

### 5. Validate Quote Accuracy
Cross-reference script output with:
- DEX UI quotes for same trade size
- GeckoTerminal pool prices
- DEX Screener data

## Troubleshooting

### Common Issues

**RPC Connection Failed**
```
Error: Failed to connect to HyperEVM RPC
```
- Solution: Verify RPC endpoint is accessible
- Note: RPC has 100 req/min rate limit
- Alternative: Wait and retry, or use backup RPC if available

**Contract Call Reverts**
```
Error: execution reverted
```
- Cause: Insufficient liquidity, wrong contract address, or pool doesn't exist
- Solution: Verify pool exists on DEX UI, check contract address is correct

**Rate Limit Exceeded**
```
Error: Too Many Requests
```
- Cause: Exceeded 100 requests/minute to HyperEVM RPC
- Solution: Add delays between requests, reduce trade sizes tested

**All Quotes Return Errors**
```
Disabled (pending addresses): 11
```
- Expected: Contract addresses not yet configured
- Solution: Update DEX_CONFIGS with addresses as they become available

## Dependencies

```json
{
  "ethers": "^6.15.0"
}
```

No additional DEX-specific SDKs are currently available for HyperEVM DEXs.

## Future Enhancements

### When More DEXs Are Available

1. **Add More DEX Types**: Support for orderbook DEXs, RFQ models
2. **Historical Tracking**: Record metrics over time for trend analysis
3. **Liquidity Depth Analysis**: Test multiple trade sizes to map liquidity
4. **Gas Cost Inclusion**: Calculate all-in costs including gas fees
5. **Arbitrage Detection**: Identify profitable cross-DEX opportunities

### Integration with Hyperliquid Native

For comprehensive HYPE liquidity analysis, integrate Hyperliquid's L1 orderbook:

```typescript
// Future: Hyperliquid Native integration via WebSocket API
async function getHyperliquidL1Quote(amountIn: bigint) {
  // Connect to wss://api.hyperliquid.xyz/ws
  // Subscribe to HYPE/USDC orderbook
  // Calculate fillable amount at given price levels
}
```

## Resources

### Official Documentation
- [HyperEVM Docs](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm)
- [Hyperliquid API](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api)
- [HyperEVMScan](https://hyperevmscan.io)

### DEX Websites
- HyperSwap: https://hyperswap.exchange
- Project X: https://prjx.com
- Hybra Finance: https://hybra.finance
- Upheaval: https://upheaval.fi
- Kittenswap: https://kittenswap.finance
- HyperBrick: https://hyperbrick.xyz
- HX Finance: https://hx.finance

### Data Aggregators
- [GeckoTerminal](https://www.geckoterminal.com/hyperevm) - Pool data and prices
- [DEX Screener](https://dexscreener.com/hyperevm) - Real-time DEX analytics
- [DefiLlama](https://defillama.com/chain/HyperEVM) - TVL tracking

## Changelog

### 2025-10-02
- Initial HyperEVM implementation created
- Researched and documented 11 DEX protocols
- Implemented quote fetching framework for Uniswap V2/V3 clones
- Created CSV export functionality
- Documented integration challenges and next steps
- Script structure ready for contract addresses when available

---

**Last Updated**: October 2, 2025
**Maintainer**: PepayLabs
**Status**: Pending Contract Addresses
