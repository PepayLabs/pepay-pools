#!/usr/bin/env node
const { ethers } = require("ethers");

// ---- Chain RPC defaults (override with --rpc if you like) ----
const RPC = {
  base: "https://mainnet.base.org",
  bnb:  "https://bsc-dataseed.binance.org",
};

// ---- APRO feeds: AggregatorV3-style contracts per pair ----
// Source: APRO docs → Data Push → Price Feed Contract (Base, BNB)  (see citations)
const APRO_FEEDS = {
  base: {
    "BTC/USD": "0xc25dD8C66b05C1C704339a73B6d21fB6076c5601", // Base Mainnet
  },
  bnb: {
    "BNB/USD": "0xE3571D2426E842fa3422E1610678506EB34675F6",
    "ETH/USD": "0xc7c18F507617eac8CAF15d4aaa9D208ad1314F67",
    "BTC/USD": "0xD71E8d3A49A5325F41e5c50F04E74C7281b37f9D",
    "USDC/USD":"0x463e8F1CB7F663afee6e66717FE0b896FBA9689C",
    "FDUSD/USD":"0x2570308fE6Ec17f3A50FB4C806EE7572d452C124",
    // (docs also list USDT/USD etc.; add here if you need them)
  },
};

// ---- Minimal AggregatorV3 ABI (read-only) ----
const AGG_V3_ABI = [
  "function decimals() view returns (uint8)",
  "function description() view returns (string)",
  "function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)"
];

// ---- CLI ----
function parseArgs() {
  const a = process.argv.slice(2);
  const get = f => { const i = a.indexOf(f); return i >= 0 ? a[i+1] : undefined; };
  const chain = (get("--chain") || "base").toLowerCase();    // base | bnb
  const rpc   = get("--rpc") || RPC[chain];
  if (!APRO_FEEDS[chain]) {
    console.error(`Unsupported --chain '${chain}'. Use 'base' or 'bnb'.`);
    process.exit(1);
  }
  return { chain, rpc };
}

// ---- helpers ----
const tsUTC = s => new Date(Number(s) * 1000).toISOString().replace('T',' ').replace('Z',' UTC');

async function main() {
  const { chain, rpc } = parseArgs();
  const provider = new ethers.JsonRpcProvider(rpc);

  const rows = [];
  for (const [pair, addr] of Object.entries(APRO_FEEDS[chain])) {
    try {
      const feed = new ethers.Contract(addr, AGG_V3_ABI, provider);
      const [dec, desc, rd] = await Promise.all([
        feed.decimals(),
        feed.description(),
        feed.latestRoundData()
      ]);
      const answer    = rd[1];        // int256
      const updatedAt = rd[3];        // uint256
      const price     = Number(answer) / 10 ** Number(dec);
      const ageSec    = Math.floor(Date.now()/1000) - Number(updatedAt);

      rows.push({
        chain,
        pair,
        address: addr,
        description: desc,
        decimals: String(dec),
        price: price.toPrecision(10),
        updatedAtUtc: tsUTC(updatedAt),
        ageSec
      });
    } catch (e) {
      rows.push({ chain, pair, address: addr, error: e.message || String(e) });
    }
  }
  // show stalest first
  rows.sort((a,b) => (b.ageSec ?? 0) - (a.ageSec ?? 0));
  console.table(rows);
}

main().catch(e => { console.error(e); process.exit(1); });
