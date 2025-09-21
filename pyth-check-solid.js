#!/usr/bin/env node
const { ethers } = require("ethers");

// ---- Minimal ABI with getPriceUnsafe ----
const PYTH_ABI = [
  {
    "inputs":[{"internalType":"bytes32","name":"id","type":"bytes32"}],
    "name":"getPriceUnsafe",
    "outputs":[{"components":[
      {"internalType":"int64","name":"price","type":"int64"},
      {"internalType":"uint64","name":"conf","type":"uint64"},
      {"internalType":"int32","name":"expo","type":"int32"},
      {"internalType":"uint","name":"publishTime","type":"uint"}
    ],"internalType":"struct PythStructs.Price","name":"price","type":"tuple"}],
    "stateMutability":"view","type":"function"
  }
];

// ---- Hard-coded RPC + Pyth price-feed contracts ----
// Update these if you want, or override with --pyth on CLI.
const DEFAULTS = {
  rpc: {
    base: "https://mainnet.base.org",
    bnb:  "https://bsc-dataseed.binance.org"
  },
  pyth: {
    base: "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a", // Base
    bnb:  "0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594"  // BNB
  }
};

// ---- Feed IDs (bytes32) ----
// These IDs are chain-agnostic; the feed must have been posted at least once on that chain.
const FEEDS = {
  BNB_USD:  "0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f",
  ETH_USD:  "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
  BTC_USD:  "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  USDC_USD: "0x2fb245b9a84554a0f15aa123cbb5f64cd263b59e9a87d80148cbffab50c69f30"
};

// ---- CLI ----
function parseArgs() {
  const a = process.argv.slice(2);
  const get = f => { const i = a.indexOf(f); return i >= 0 ? a[i+1] : undefined; };
  const chain = (get("--chain") || "base").toLowerCase(); // base | bnb
  const rpc   = get("--rpc") || DEFAULTS.rpc[chain];
  const pyth  = get("--pyth") || DEFAULTS.pyth[chain];
  const feedsCsv = get("--feeds"); // optional custom list
  if (!DEFAULTS.rpc[chain] || !pyth) {
    console.error(`Unsupported or missing config for --chain '${chain}'. Provide --pyth or edit DEFAULTS.`);
    process.exit(1);
  }
  return { chain, rpc, pyth, feedsCsv };
}

// ---- Helpers (all BigInt-safe) ----
function formatDecimal(int64, expo) {
  // int64 * 10^expo rendered as string without losing precision
  const neg = (int64 < 0n);
  let n = neg ? -int64 : int64; // BigInt magnitude
  let e = Number(expo);         // expo is int32 but safe to Number

  if (e >= 0) {
    // append zeros
    return (neg ? "-" : "") + (n.toString() + "0".repeat(e));
  }
  // e < 0: insert decimal point
  const s = n.toString();
  const k = s.length + e; // e is negative
  if (k > 0) {
    return (neg ? "-" : "") + s.slice(0, k) + "." + s.slice(k);
  } else {
    return (neg ? "-" : "") + "0." + "0".repeat(-k) + s;
  }
}

const toUTC = (secBig) => new Date(Number(secBig) * 1000).toISOString().replace('T',' ').replace('Z',' UTC');

async function main() {
  const { chain, rpc, pyth, feedsCsv } = parseArgs();
  const provider = new ethers.JsonRpcProvider(rpc);
  const c = new ethers.Contract(pyth, PYTH_ABI, provider);

  const ids = feedsCsv
    ? feedsCsv.split(",").map(s => s.trim())
    : [FEEDS.BNB_USD, FEEDS.ETH_USD, FEEDS.BTC_USD, FEEDS.USDC_USD];

  const now = BigInt(Math.floor(Date.now()/1000));
  const rows = [];

  for (const id of ids) {
    try {
      const p = await c.getPriceUnsafe(id);
      // p fields are BigInt/int, keep them safe
      const priceStr = formatDecimal(BigInt(p.price), p.expo);
      const confStr  = formatDecimal(BigInt(p.conf), p.expo); // same scale as price
      const ageSec   = (now - BigInt(p.publishTime));

      rows.push({
        chain,
        pyth,
        feedId: id,
        price: priceStr,
        conf: confStr,
        expo: String(p.expo),
        publishTimeUtc: toUTC(p.publishTime),
        ageSec: ageSec.toString()
      });
    } catch (e) {
      // Most common revert on empty chain: "price not found"/custom error
      rows.push({
        chain,
        pyth,
        feedId: id,
        error: (e && e.message) ? e.message : String(e),
        hint: "Likely no on-chain update yet for this feed on this chain. Once any app posts via updatePriceFeeds(), reads will work."
      });
    }
  }

  console.table(rows);
}

main().catch(e => { console.error(e); process.exit(1); });
