/**
 * Quick connectivity and quote test for Avalanche DEX integrations
 */

import { ethers } from 'ethers';

const AVALANCHE_RPC = 'https://api.avax.network/ext/bc/C/rpc';
const TOKENS = {
  USDC: '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E',
  WAVAX: '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7',
};

const UNISWAP_QUOTER_V2 = '0xbe0F5544EC67e9B3b2D979aaA43f18Fd87E6257F';
const QUOTER_ABI = [
  'function quoteExactInputSingle((address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint160 sqrtPriceLimitX96)) external returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)',
];

async function test() {
  console.log('\nAvalanche DEX Integration Test');
  console.log('='.repeat(50));

  // Test 1: RPC Connectivity
  console.log('\n1. Testing RPC connectivity...');
  const provider = new ethers.JsonRpcProvider(AVALANCHE_RPC);

  try {
    const network = await provider.getNetwork();
    console.log(`✅ Connected to Avalanche C-Chain (chainId: ${network.chainId})`);

    const blockNumber = await provider.getBlockNumber();
    console.log(`✅ Current block: ${blockNumber}`);
  } catch (error: any) {
    console.error(`❌ RPC connection failed: ${error.message}`);
    process.exit(1);
  }

  // Test 2: Token balances (verify tokens exist)
  console.log('\n2. Verifying token contracts...');
  try {
    const usdcCode = await provider.getCode(TOKENS.USDC);
    const wavaxCode = await provider.getCode(TOKENS.WAVAX);

    if (usdcCode === '0x') {
      console.error(`❌ USDC contract not found at ${TOKENS.USDC}`);
    } else {
      console.log(`✅ USDC contract exists (${usdcCode.length} bytes)`);
    }

    if (wavaxCode === '0x') {
      console.error(`❌ WAVAX contract not found at ${TOKENS.WAVAX}`);
    } else {
      console.log(`✅ WAVAX contract exists (${wavaxCode.length} bytes)`);
    }
  } catch (error: any) {
    console.error(`❌ Token verification failed: ${error.message}`);
  }

  // Test 3: Uniswap Quoter
  console.log('\n3. Testing Uniswap V3 Quoter...');
  try {
    const quoter = new ethers.Contract(UNISWAP_QUOTER_V2, QUOTER_ABI, provider);
    const testAmount = ethers.parseUnits('100', 6); // 100 USDC

    const params = {
      tokenIn: TOKENS.USDC,
      tokenOut: TOKENS.WAVAX,
      amountIn: testAmount,
      fee: 3000, // 0.3%
      sqrtPriceLimitX96: 0,
    };

    console.log(`   Requesting quote for ${ethers.formatUnits(testAmount, 6)} USDC...`);
    const result = await quoter.quoteExactInputSingle.staticCall(params);

    const amountOut = result[0];
    const gasEstimate = result[3];

    console.log(`✅ Quote successful:`);
    console.log(`   Input: 100 USDC`);
    console.log(`   Output: ${ethers.formatUnits(amountOut, 18)} AVAX`);
    console.log(`   Price: ${(100 / Number(ethers.formatUnits(amountOut, 18))).toFixed(2)} USDC/AVAX`);
    console.log(`   Gas estimate: ${gasEstimate.toString()}`);
  } catch (error: any) {
    console.error(`❌ Uniswap quote failed: ${error.message}`);
    if (error.data) {
      console.error(`   Error data: ${error.data}`);
    }
  }

  console.log('\n' + '='.repeat(50));
  console.log('Test complete!\n');
}

test().catch(error => {
  console.error('\nFatal error:', error);
  process.exit(1);
});
