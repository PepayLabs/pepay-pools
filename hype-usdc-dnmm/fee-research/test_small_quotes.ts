/**
 * Test all enabled DEXs with a small trade amount
 * This helps us identify any integration issues before running the full suite
 */

import { ethers } from 'ethers';
import { aggregateQuotes } from './evaluate_avax.js';
import type { QuoteResult } from './evaluate_avax.js';

const AVALANCHE_RPC = 'https://api.avax.network/ext/bc/C/rpc';

// Override TRADE_SIZES for quick test - just test $100
process.env.TEST_MODE = 'true';

async function quickTest() {
  console.log('\nQuick DEX Integration Test');
  console.log('Testing all enabled DEXs with $100 USDC trade');
  console.log('='.repeat(60));

  const provider = new ethers.JsonRpcProvider(AVALANCHE_RPC);

  // Test with 100 USDC
  const testAmount = ethers.parseUnits('100', 6);

  console.log('\nAttempting to fetch quotes from all enabled DEXs...\n');

  try {
    // This will test all enabled DEXs
    const results: QuoteResult[] = await aggregateQuotes(provider);

    console.log('\n' + '='.repeat(60));
    console.log('RESULTS SUMMARY');
    console.log('='.repeat(60));

    const successful = results.filter((result) => !result.error);
    const failed = results.filter((result) => result.error);

    console.log(`\nSuccessful: ${successful.length}`);
    successful.forEach((result) => {
      console.log(`  ✅ ${result.dex}: ${result.amountOutFormatted} AVAX (${result.effectivePrice} USDC/AVAX)`);
    });

    console.log(`\nFailed: ${failed.length}`);
    failed.forEach((result) => {
      console.log(`  ❌ ${result.dex}: ${result.error}`);
    });

    console.log('\n' + '='.repeat(60));

    if (failed.length > 0) {
      console.log('\n⚠️  Some DEX integrations failed. Review errors above.');
      console.log('You can disable failing DEXs in DEX_CONFIGS or fix the integration.');
    }

    if (successful.length > 0) {
      console.log('\n✅ At least some DEXs are working! Ready to run full suite.');
    }

  } catch (error: any) {
    console.error(`\n❌ Test failed: ${error.message}`);
    console.error(error.stack);
    process.exit(1);
  }
}

quickTest();
