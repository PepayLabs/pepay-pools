// test-precompiles.ts - Test ALL HyperCore precompiles to find correct spot price
import { loadEnv } from './env.js';

loadEnv();
import { AbiCoder, JsonRpcProvider } from 'ethers';

const RPC_URL = process.env.RPC_URL || '';

// Test different keys
const HYPE_TOKEN_ID = 150;       // Base token ID
const HYPE_USDC_MARKET_ID = 107; // Spot market ID
const HYPE_PERP_INDEX = 159;     // Perp index

// ALL HyperCore precompiles
const PRECOMPILES = {
  MARK_PX: '0x0000000000000000000000000000000000000806',
  ORACLE_PX: '0x0000000000000000000000000000000000000807',
  SPOT_PX: '0x0000000000000000000000000000000000000808',
  BBO: '0x000000000000000000000000000000000000080e'
};

const coder = AbiCoder.defaultAbiCoder();
const provider = new JsonRpcProvider(RPC_URL);

function encodeKey(index: number): string {
  return coder.encode(['uint32'], [index]);
}

function tryDecode(hex: string): { uint64?: bigint; uint32?: number; bytes?: string } {
  const result: any = {};

  try {
    const [u64] = coder.decode(['uint64'], hex) as unknown as [bigint];
    result.uint64 = u64;
  } catch {}

  try {
    const [u32] = coder.decode(['uint32'], hex) as unknown as [number];
    result.uint32 = u32;
  } catch {}

  result.bytes = hex;
  return result;
}

function testScaling(raw: bigint): Record<string, string> {
  const scalings = {
    '× 10^6  (spot sz=2)': Number(raw) / 1e6,
    '× 10^8  (spot sz=0)': Number(raw) / 1e8,
    '× 10^4  (perp sz=2)': Number(raw) / 1e4,
    '÷ 10^12 (inverse)': Number(raw) * 1e12,
    'raw value': Number(raw)
  };

  const results: Record<string, string> = {};
  for (const [label, val] of Object.entries(scalings)) {
    const formatted = val.toFixed(6);
    const marker = val >= 40 && val <= 55 ? ' ✅' : '';
    results[label] = `$${formatted}${marker}`;
  }
  return results;
}

async function testPrecompile(name: string, address: string, key: number, keyLabel: string) {
  console.log(`\n${'═'.repeat(70)}`);
  console.log(`🔍 ${name} (${address}) with key ${key} (${keyLabel})`);
  console.log('═'.repeat(70));

  const arg = encodeKey(key);

  try {
    const response = await provider.call({ to: address, data: arg });
    console.log(`✅ Response: ${response.slice(0, 66)}${response.length > 66 ? '...' : ''}`);
    console.log(`📏 Length: ${response.length} bytes`);

    const decoded = tryDecode(response);

    if (decoded.uint64 !== undefined) {
      console.log(`\n🔢 Decoded as uint64: ${decoded.uint64}`);
      console.log(`\n💰 Price scaling attempts:`);
      const scalings = testScaling(decoded.uint64);
      for (const [method, result] of Object.entries(scalings)) {
        console.log(`   ${method.padEnd(20)} → ${result}`);
      }
    }

    if (decoded.uint32 !== undefined && decoded.uint32 !== Number(decoded.uint64)) {
      console.log(`\n🔢 Decoded as uint32: ${decoded.uint32}`);
    }

  } catch (e: any) {
    console.log(`❌ Error: ${e.message}`);
    if (e.message.includes('PrecompileError')) {
      console.log(`   → Wrong key for this precompile`);
    }
  }
}

async function main() {
  console.log('\n╔════════════════════════════════════════════════════════════════════╗');
  console.log('║         HyperCore Precompile Exhaustive Test                      ║');
  console.log('║         Target: HYPE spot price ≈ $47 USD                         ║');
  console.log('╚════════════════════════════════════════════════════════════════════╝');
  console.log(`\n🌐 RPC: ${RPC_URL}\n`);

  // Test each precompile with different keys
  const tests = [
    // MARK_PX tests
    { name: 'MARK_PX', addr: PRECOMPILES.MARK_PX, key: HYPE_TOKEN_ID, label: 'HYPE token ID' },
    { name: 'MARK_PX', addr: PRECOMPILES.MARK_PX, key: HYPE_USDC_MARKET_ID, label: 'HYPE/USDC market ID' },
    { name: 'MARK_PX', addr: PRECOMPILES.MARK_PX, key: HYPE_PERP_INDEX, label: 'HYPE perp index' },

    // ORACLE_PX tests
    { name: 'ORACLE_PX', addr: PRECOMPILES.ORACLE_PX, key: HYPE_TOKEN_ID, label: 'HYPE token ID' },
    { name: 'ORACLE_PX', addr: PRECOMPILES.ORACLE_PX, key: HYPE_USDC_MARKET_ID, label: 'HYPE/USDC market ID' },
    { name: 'ORACLE_PX', addr: PRECOMPILES.ORACLE_PX, key: HYPE_PERP_INDEX, label: 'HYPE perp index' },

    // SPOT_PX tests (THIS IS THE KEY ONE!)
    { name: 'SPOT_PX', addr: PRECOMPILES.SPOT_PX, key: HYPE_TOKEN_ID, label: 'HYPE token ID' },
    { name: 'SPOT_PX', addr: PRECOMPILES.SPOT_PX, key: HYPE_USDC_MARKET_ID, label: 'HYPE/USDC market ID' },
    { name: 'SPOT_PX', addr: PRECOMPILES.SPOT_PX, key: HYPE_PERP_INDEX, label: 'HYPE perp index' },

    // BBO tests
    { name: 'BBO', addr: PRECOMPILES.BBO, key: HYPE_TOKEN_ID, label: 'HYPE token ID' },
    { name: 'BBO', addr: PRECOMPILES.BBO, key: HYPE_USDC_MARKET_ID, label: 'HYPE/USDC market ID' },
    { name: 'BBO', addr: PRECOMPILES.BBO, key: HYPE_PERP_INDEX, label: 'HYPE perp index' }
  ];

  for (const test of tests) {
    await testPrecompile(test.name, test.addr, test.key, test.label);
    await new Promise(r => setTimeout(r, 100)); // Rate limit
  }

  console.log(`\n${'═'.repeat(70)}`);
  console.log('🎯 Look for values marked with ✅ (between $40-$55)');
  console.log('═'.repeat(70));
  console.log();
}

main().catch(e => {
  console.error('Fatal:', e);
  process.exit(1);
});
