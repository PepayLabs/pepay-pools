#!/usr/bin/env node
const { ethers } = require("ethers");

// --- Minimal IPyth read-only ABI ---
const PYTH_ABI = [
  {
    "inputs":[{"internalType":"bytes32","name":"id","type":"bytes32"}],
    "name":"getPrice",
    "outputs":[{"components":[
      {"internalType":"int64","name":"price","type":"int64"},
      {"internalType":"uint64","name":"conf","type":"uint64"},
      {"internalType":"int32","name":"expo","type":"int32"},
      {"internalType":"uint","name":"publishTime","type":"uint"}
    ],"internalType":"struct PythStructs.Price","name":"price","type":"tuple"}],
    "stateMutability":"view","type":"function"
  }
];

// --- Edit these once (from Pyth docs) ---
const DEFAULTS = {
  rpc: {
    base: "https://mainnet.base.org",
    bnb:  "https://bsc-dataseed.binance.org"
  },
  // Paste the official IPyth price-feed contract addresses here:
  pyth: {
    base: "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a", // e.g. "0x........" (Base mainnet IPyth address)
    bnb:  "0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594"  // e.g. "0x........" (BNB Smart Chain IPyth address)
  }
};

// --- CLI parse ---
function parseArgs() {
  const args = process.argv.slice(2);
  const get = f => {
    const i = args.indexOf(f);
    return i >= 0 ? args[i+1] : undefined;
  };
  const chain   = (get("--chain") || "base").toLowerCase(); // base | bnb
  const rpc     = get("--rpc") || DEFAULTS.rpc[chain];
  const pythAdr = get("--pyth") || DEFAULTS.pyth[chain];
  const feeds   = get("--feeds");
  const symbols = get("--symbols");

  if (!rpc) {
    console.error(`Missing RPC for '${chain}'. Pass --rpc or edit DEFAULTS.rpc.`);
    process.exit(1);
  }
  if (!pythAdr) {
    console.error(
      `Missing Pyth contract for '${chain}'. Pass --pyth <address> ` +
      `or paste the address into DEFAULTS.pyth.${chain}.`
    );
    console.error("Find it here: https://docs.pyth.network/price-feeds/contract-addresses/evm");
    process.exit(2);
  }
  if (!feeds && !symbols) {
    console.error("Pass --feeds <id1,id2,...> or --symbols <sym1,sym2,...>");
    console.error("Example symbols: Crypto.BNB/USD,Crypto.ETH/USD,Crypto.BTC/USD,Stable.USDC/USD");
    process.exit(3);
  }
  return { chain, rpc, pythAdr, feeds, symbols };
}

// Resolve symbols -> feed IDs (via Pyth price service)
async function resolveSymbolsToIds(symbols) {
  const res = await fetch("https://xc-mainnet.pyth.network/api/latest_price_feeds");
  if (!res.ok) throw new Error(`Fetch latest_price_feeds failed: ${res.status}`);
  const all = await res.json();
  const map = new Map();
  for (const f of all) if (f.product_symbol && f.id) map.set(f.product_symbol, f.id);
  return symbols.map(s => {
    const id = map.get(s);
    if (!id) throw new Error(`Symbol not found: ${s}`);
    return id;
  });
}

const scalePrice = (intPrice, expo) => Number(intPrice) * Math.pow(10, expo);
const toBps = (conf, priceAbs) => (priceAbs === 0 ? 0 : (Number(conf) / priceAbs) * 1e4);
const tsToUtc = ts => new Date(Number(ts) * 1000).toISOString().replace('T',' ').replace('Z',' UTC');

async function main() {
  const { chain, rpc, pythAdr, feeds, symbols } = parseArgs();
  const provider = new ethers.JsonRpcProvider(rpc);
  const pyth = new ethers.Contract(pythAdr, PYTH_ABI, provider);

  // Resolve feed IDs
  let feedIds;
  if (feeds) {
    feedIds = feeds.split(",").map(s => s.trim());
  } else {
    const syms = symbols.split(",").map(s => s.trim());
    feedIds = await resolveSymbolsToIds(syms);
  }

  const now = Math.floor(Date.now()/1000);
  const rows = [];
  for (const id of feedIds) {
    try {
      const p = await pyth.getPrice(id);
      const price = scalePrice(p.price, p.expo);
      const confBps = toBps(p.conf, Math.abs(price));
      const ageSec = now - Number(p.publishTime);
      rows.push({
        chain, pyth: pythAdr, feedId: id,
        price: price.toPrecision(10),
        expo: p.expo.toString(),
        confBps: confBps.toFixed(2),
        publishTimeUtc: tsToUtc(p.publishTime),
        ageSec
      });
    } catch (e) {
      rows.push({ chain, pyth: pythAdr, feedId: id, error: e.message || String(e) });
    }
  }
  rows.sort((a,b)=> (b.ageSec??0) - (a.ageSec??0));
  console.table(rows);
}

main().catch(err => { console.error(err); process.exit(1); });
