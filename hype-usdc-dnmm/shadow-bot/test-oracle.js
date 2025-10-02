// test-oracle.ts - Diagnostic test for HYPE oracle pricing
import 'dotenv/config';
import { AbiCoder, Contract, JsonRpcProvider, getBigInt } from 'ethers';
const RPC_URL = process.env.RPC_URL || '';
const USE_SPOT = process.env.USE_SPOT === 'true';
// Keys (CORRECTED after testing)
const ORACLE_PRICE_KEY = USE_SPOT ? 107 : 159; // HYPE/USDC market ID (107) for spot, perp index (159) for perp
const MARKET_KEY_INDEX = USE_SPOT ? 107 : 159; // HYPE/USDC spot market (107)
// Price scaling
const PRICE_SCALE_MULTIPLIER = USE_SPOT ? 1e12 : 1e14;
// Precompiles (CORRECTED after testing)
const ORACLE_PX = USE_SPOT
    ? '0x0000000000000000000000000000000000000808' // SPOT_PX for spot
    : '0x0000000000000000000000000000000000000807'; // ORACLE_PX for perp
const BBO = '0x000000000000000000000000000000000000080e';
// Pyth
const PYTH_ADDR = process.env.PYTH_ADDR || '0xe9d69CdD6Fe41e7B621B4A688C5D1a68cB5c8ADc';
const PYTH_BASE_FEED_ID = '0x4279e31cc369bbcc2faf022b382b080e32a8e689ff20fbc530d2a603eb6cd98b'; // HYPE/USD
const PYTH_QUOTE_FEED_ID = '0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a'; // USDC/USD
const coder = AbiCoder.defaultAbiCoder();
const provider = new JsonRpcProvider(RPC_URL);
const PYTH_ABI = [
    'function getPriceUnsafe(bytes32 id) external view returns (int64 price, uint64 conf, int32 expo, uint64 publishTime)'
];
function encodeMarketKey32(index) {
    return coder.encode(['uint32'], [index]);
}
function toWadFromHC(rawPrice) {
    return rawPrice * BigInt(PRICE_SCALE_MULTIPLIER);
}
function toWadFromPyth(price, expo) {
    const e = BigInt(expo);
    if (e === -18n)
        return price;
    if (e > -18n)
        return price * 10n ** (e + 18n);
    return price / 10n ** (-18n - e);
}
function formatWad(wad) {
    const dollars = Number(wad) / 1e18;
    return dollars.toFixed(6);
}
async function testOraclePx() {
    const precompileName = USE_SPOT ? 'SPOT_PX (0x0808)' : 'ORACLE_PX (0x0807)';
    console.log('\n═══════════════════════════════════════════════════════════════');
    console.log(`🔍 Testing ${precompileName} - Mid Price Oracle`);
    console.log('═══════════════════════════════════════════════════════════════');
    const arg = encodeMarketKey32(ORACLE_PRICE_KEY);
    console.log(`📌 Using key: ${ORACLE_PRICE_KEY} (${USE_SPOT ? 'HYPE/USDC market ID' : 'HYPE perp index'})`);
    console.log(`📦 Encoded arg: ${arg}`);
    try {
        const pxBytes = await provider.call({ to: ORACLE_PX, data: arg });
        console.log(`✅ Response length: ${pxBytes.length} bytes`);
        console.log(`📄 Raw hex: ${pxBytes}`);
        let pxU64;
        if (pxBytes.length === 8 || pxBytes.length === 10) {
            pxU64 = BigInt(pxBytes);
            console.log(`🔢 Decoded as raw 8 bytes: ${pxU64}`);
        }
        else {
            const [decoded] = coder.decode(['uint64'], pxBytes);
            pxU64 = decoded;
            console.log(`🔢 Decoded as ABI uint64: ${pxU64}`);
        }
        const midWad = toWadFromHC(pxU64);
        console.log(`\n💰 RAW VALUE: ${pxU64}`);
        console.log(`💰 SCALING: ${pxU64} × ${PRICE_SCALE_MULTIPLIER} = ${midWad}`);
        console.log(`💵 PRICE (WAD): ${formatWad(midWad)} USD`);
        console.log(`\n🎯 Expected: ~$47.00 USD`);
        const priceNum = Number(formatWad(midWad));
        if (priceNum >= 40 && priceNum <= 55) {
            console.log(`✅ PRICE LOOKS CORRECT!`);
        }
        else {
            console.log(`⚠️  PRICE LOOKS WRONG! Check scaling or key.`);
        }
        return { raw: pxU64, wad: midWad };
    }
    catch (e) {
        console.error(`❌ Error reading oraclePx: ${e.message}`);
        if (e.message.includes('PrecompileError')) {
            console.error(`\n⚠️  PrecompileError means wrong key!`);
            console.error(`   For spot: use BASE TOKEN ID (150 for HYPE)`);
            console.error(`   For perp: use PERP INDEX (159 for HYPE)`);
        }
        return null;
    }
}
async function testBbo() {
    console.log('\n═══════════════════════════════════════════════════════════════');
    console.log('📊 Testing bbo (0x080e) - Bid/Ask Spread');
    console.log('═══════════════════════════════════════════════════════════════');
    const arg = encodeMarketKey32(MARKET_KEY_INDEX);
    console.log(`📌 Using key: ${MARKET_KEY_INDEX} (${USE_SPOT ? 'HYPE/USDC market ID' : 'perp index'})`);
    console.log(`📦 Encoded arg: ${arg}`);
    try {
        const bboBytes = await provider.call({ to: BBO, data: arg });
        console.log(`✅ Response length: ${bboBytes.length} bytes`);
        console.log(`📄 Raw hex: ${bboBytes}`);
        let bidU64;
        let askU64;
        if (bboBytes.length === 16 || bboBytes.length === 18) {
            const bidHex = bboBytes.slice(0, 18);
            const askHex = '0x' + bboBytes.slice(18);
            bidU64 = BigInt(bidHex);
            askU64 = BigInt(askHex);
            console.log(`🔢 Decoded as raw 16 bytes: bid=${bidU64}, ask=${askU64}`);
        }
        else {
            const decoded = coder.decode(['uint64', 'uint64'], bboBytes);
            bidU64 = decoded[0];
            askU64 = decoded[1];
            console.log(`🔢 Decoded as ABI (uint64,uint64): bid=${bidU64}, ask=${askU64}`);
        }
        const bidWad = toWadFromHC(bidU64);
        const askWad = toWadFromHC(askU64);
        console.log(`\n💰 BID: ${formatWad(bidWad)} USD (raw: ${bidU64})`);
        console.log(`💰 ASK: ${formatWad(askWad)} USD (raw: ${askU64})`);
        const spreadBps = Number((10000n * (askWad - bidWad)) / ((bidWad + askWad) / 2n));
        console.log(`📏 SPREAD: ${spreadBps.toFixed(2)} bps`);
        return { bid: bidWad, ask: askWad, spreadBps };
    }
    catch (e) {
        console.error(`❌ Error reading bbo: ${e.message}`);
        return null;
    }
}
async function testPyth() {
    console.log('\n═══════════════════════════════════════════════════════════════');
    console.log('🐍 Testing Pyth Network - HYPE/USD Price');
    console.log('═══════════════════════════════════════════════════════════════');
    try {
        const pyth = new Contract(PYTH_ADDR, PYTH_ABI, provider);
        // Read HYPE/USD
        console.log(`\n📌 Reading HYPE/USD feed: ${PYTH_BASE_FEED_ID}`);
        const rb = await pyth.getPriceUnsafe(PYTH_BASE_FEED_ID);
        const hypePrice = getBigInt(rb[0]);
        const hypeConf = getBigInt(rb[1]);
        const hypeExpo = Number(rb[2]);
        const hypeTs = Number(rb[3]);
        console.log(`📊 Raw price: ${hypePrice}`);
        console.log(`📊 Confidence: ${hypeConf}`);
        console.log(`📊 Exponent: ${hypeExpo}`);
        console.log(`📊 Timestamp: ${hypeTs} (age: ${Math.floor(Date.now() / 1000) - hypeTs}s)`);
        const hypeWad = toWadFromPyth(hypePrice, hypeExpo);
        console.log(`💵 HYPE/USD: ${formatWad(hypeWad)} USD`);
        // Read USDC/USD
        console.log(`\n📌 Reading USDC/USD feed: ${PYTH_QUOTE_FEED_ID}`);
        const rq = await pyth.getPriceUnsafe(PYTH_QUOTE_FEED_ID);
        const usdcPrice = getBigInt(rq[0]);
        const usdcConf = getBigInt(rq[1]);
        const usdcExpo = Number(rq[2]);
        const usdcTs = Number(rq[3]);
        console.log(`📊 Raw price: ${usdcPrice}`);
        console.log(`📊 Confidence: ${usdcConf}`);
        console.log(`📊 Exponent: ${usdcExpo}`);
        console.log(`📊 Timestamp: ${usdcTs} (age: ${Math.floor(Date.now() / 1000) - usdcTs}s)`);
        const usdcWad = toWadFromPyth(usdcPrice, usdcExpo);
        console.log(`💵 USDC/USD: ${formatWad(usdcWad)} USD`);
        // Calculate HYPE/USDC
        const pairMid = (hypeWad * 10n ** 18n) / usdcWad;
        console.log(`\n💱 HYPE/USDC (derived): ${formatWad(pairMid)} USD`);
        console.log(`🎯 Expected: ~$47.00 USD`);
        const priceNum = Number(formatWad(pairMid));
        if (priceNum >= 40 && priceNum <= 55) {
            console.log(`✅ PYTH PRICE LOOKS CORRECT!`);
        }
        else {
            console.log(`⚠️  PYTH PRICE LOOKS WRONG!`);
        }
        return { mid: pairMid, conf: hypeConf };
    }
    catch (e) {
        console.error(`❌ Error reading Pyth: ${e.message}`);
        return null;
    }
}
async function compareOracles() {
    console.log('\n═══════════════════════════════════════════════════════════════');
    console.log('⚖️  Oracle Comparison');
    console.log('═══════════════════════════════════════════════════════════════');
    const hc = await testOraclePx();
    const bbo = await testBbo();
    const pyth = await testPyth();
    if (hc && pyth) {
        const hcPrice = Number(formatWad(hc.wad));
        const pythPrice = Number(formatWad(pyth.mid));
        const diff = Math.abs(hcPrice - pythPrice);
        const diffBps = Math.round((diff / pythPrice) * 10000);
        console.log(`\n📊 HyperCore: $${hcPrice.toFixed(6)}`);
        console.log(`📊 Pyth:      $${pythPrice.toFixed(6)}`);
        console.log(`📊 Difference: $${diff.toFixed(6)} (${diffBps} bps)`);
        if (diffBps <= 75) {
            console.log(`✅ Oracles agree (within 75 bps threshold)`);
        }
        else {
            console.log(`⚠️  Oracles diverged (exceeds 75 bps threshold)`);
        }
    }
}
async function main() {
    console.log('\n╔═══════════════════════════════════════════════════════════════╗');
    console.log('║         HYPE Oracle Diagnostic Test                          ║');
    console.log('╚═══════════════════════════════════════════════════════════════╝');
    console.log(`\n🌐 RPC: ${RPC_URL}`);
    console.log(`📍 Mode: ${USE_SPOT ? 'SPOT' : 'PERP'}`);
    console.log(`🎯 Expected HYPE price: ~$47.00 USD\n`);
    await compareOracles();
    console.log('\n═══════════════════════════════════════════════════════════════\n');
}
main().catch(e => {
    console.error('Fatal error:', e);
    process.exit(1);
});
