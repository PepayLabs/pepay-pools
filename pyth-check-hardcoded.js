#!/usr/bin/env node
const { ethers } = require("ethers");

// ===== EVM read-only ABI =====
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

// ===== Hard-coded RPC + Pyth contract addresses =====
// Base Pyth Price Feed contract (official docs):
// 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a
// BNB Chain Pyth Price Feed contract (official docs):
// 0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594
const DEFAULTS = {
  rpc: {
    base: "https://mainnet.base.org",
    bnb:  "https://bsc-dataseed.binance.org"
  },
  pyth: {
    base: "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a",
    bnb:  "0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594"
  }
};

// ===== Hard-coded Pyth feed IDs (32-byte hex, same across chains) =====
// ETH/USD
const ETH_USD = "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace";
// BTC/USD
const BTC_USD = "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43";
// BNB/USD
const BNB_USD = "0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f";
// USDC/USD
const USDC_USD = "0x2fb245b9a84554a0f15aa123cbb5f64cd263b59e9a87d80148cbffab50c69f30";

const FEEDS = [BNB_USD, ETH_USD, BTC_USD, USDC_USD];

// ===== CLI =====
function parseArgs() {
  const a = process.argv.slice(2);
  const get = f => { const i = a.indexOf(f); return i >= 0 ? a[i+1] : undefined; };
  const chain = (get("--chain") || "base").toLowerCase();   // base | bnb
  const rpc   = get("--rpc") || DEFAULTS.rpc[chain];
  const pyth  = get("--pyth") || DEFAULTS.pyth[chain];
  if (!DEFAULTS.rpc[chain] || !DEFAULTS.pyth[chain]) {
    console.error(`Unsupported --chain '${chain}'. Use 'base' or 'bnb'.`);
    process.exit(1);
  }
  if (!rpc)  { console.error("Missing RPC.");  process.exit(1); }
  if (!pyth) { console.error("Missing Pyth contract."); process.exit(1); }
  return { chain, rpc, pyth };
}

const scale = (i,e) => Number(i) * Math.pow(10, e);
const bps   = (conf, pxAbs) => (pxAbs === 0 ? 0 : (Number(conf)/pxAbs) * 1e4);
const ts    = s => new Date(Number(s)*1000).toISOString().replace('T',' ').replace('Z',' UTC');

async function main() {
  const { chain, rpc, pyth } = parseArgs();
  const provider = new ethers.JsonRpcProvider(rpc);
  const c = new ethers.Contract(pyth, PYTH_ABI, provider);

  const now = Math.floor(Date.now()/1000);
  const rows = [];
  for (const id of FEEDS) {
    try {
      const p = await c.getPrice(id);
      const price = scale(p.price, p.expo);
      const age   = now - Number(p.publishTime);
      rows.push({
        chain, pyth, feedId: id,
        price: price.toPrecision(10),
        expo: String(p.expo),
        confBps: bps(p.conf, Math.abs(price)).toFixed(2),
        publishTimeUtc: ts(p.publishTime),
        ageSec: age
      });
    } catch (e) {
      rows.push({ chain, pyth, feedId: id, error: e.message || String(e) });
    }
  }
  rows.sort((a,b) => (b.ageSec??0) - (a.ageSec??0));
  console.table(rows);
}

main().catch(e => { console.error(e); process.exit(1); });
