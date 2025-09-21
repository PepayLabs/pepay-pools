#!/usr/bin/env node
/**
 * pyth_compare_all_unified.js
 *
 * One shot, unified table comparing **Solana Pyth (SDK)** with **EVM Pyth (Base & BNB)**
 * using consistent columns:
 *   net | kind | symbol | id | status | expo | priceUsd | confUsd | confBps | publishTimeUtc | ageSec
 *
 * - Solana: reads specific Pyth **price accounts** you hardcode (no program scans),
 *           decoded via @pythnetwork/client (parsePriceData).
 * - EVM (Base/BNB): reads Pyth **Price Feed** contract via ethers, for hardcoded feed IDs.
 * - Gracefully prints `status: 'UNAVAILABLE'` on EVM feeds that currently revert.
 *
 * Usage:
 *   npm i @solana/web3.js @pythnetwork/client ethers
 *   node pyth_compare_all_unified.js --pretty
 *
 * Env (optional):
 *   SOLANA_RPC=https://api.mainnet-beta.solana.com
 *   BASE_RPC=...
 *   BNB_RPC=...
 *   STALENESS=60      // Solana freshness (seconds); set 0 to skip
 */

const { Connection, PublicKey } = require("@solana/web3.js");
const { parsePriceData, PriceStatus } = require("@pythnetwork/client");
const { ethers } = require("ethers");

// -------------------- CONFIG --------------------
const RPC = {
  sol:  process.env.SOLANA_RPC ?? "https://api.mainnet-beta.solana.com",
  base: process.env.BASE_RPC   ?? "https://mainnet.base.org",
  bnb:  process.env.BNB_RPC    ?? "https://bsc-dataseed.binance.org",
};
const STALENESS = parseInt(process.env.STALENESS ?? "60", 10);

// Hard-coded Solana price accounts you want to compare (add any others)
const FEEDS_SOL = [
  { symbol: "SOL/USD",  acc: "EPBJUVCmzvwkGPGcEuwKmXomfGt78Aozy6pj44x9xxDB" },
  { symbol: "USDC/USD", acc: "4VrjUJ7QyU3o5oxNE2LgnJDtryT7PfApD5Zw2PX8QPsh" },
  { symbol: "USDC/USD", acc: "978Mhamcn7XDkq21kvJWhUDPytJkYtkv8pqnXrUcpUxU" },
  { symbol: "USDC/USD", acc: "GCEitD54CdVVzUvvGVpB4rocCaY91LDHzeAVsD7bK8RZ" },
  { symbol: "USDT/USD", acc: "3ZDBff7jeQaksmGvmkRix36rU159EBDjYiPThvV8QVZM" },
  // Add BTC/USD on Solana when you have its account:
  // { symbol: "BTC/USD",  acc: "<PASTE_SOLANA_BTC_USD_PRICE_ACCOUNT>" },
];

// Pyth EVM Price Feed contracts (from Pyth docs)
const PYTH_EVM = {
  base: "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a", // Base
  bnb:  "0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594", // BNB
};

// Hard-coded EVM feed IDs (32-byte hex). Add more as needed.
const FEEDS_EVM = {
  base: [
    { symbol: "ETH/USD", id: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace" },
    { symbol: "BTC/USD", id: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43" },
    // { symbol: "USDC/USD", id: "0x2fb245b9a84554a0f15aa123cbb5f64cd263b59e9a87d80148cbffab50c69f30" },
  ],
  bnb: [
    { symbol: "BNB/USD", id: "0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f" },
    { symbol: "ETH/USD", id: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace" },
  ],
};

// -------------------- CLI --------------------
const args = process.argv.slice(2);
const pretty = args.includes("--pretty");

// -------------------- Helpers --------------------
const iso = (t) => t ? new Date(t*1000).toISOString().replace("T"," ").replace("Z"," UTC") : null;
const confBps = (price, conf) => {
  const p = Math.abs(Number(price));
  return p === 0 ? 0 : (Number(conf) * 1e4) / p;
};

// -------------------- EVM ABI --------------------
const PYTH_ABI = [
  {
    inputs: [{ internalType: "bytes32", name: "id", type: "bytes32" }],
    name: "getPrice",
    outputs: [{
      components: [
        { internalType: "int64",  name: "price",       type: "int64"  },
        { internalType: "uint64", name: "conf",        type: "uint64" },
        { internalType: "int32",  name: "expo",        type: "int32"  },
        { internalType: "uint",   name: "publishTime", type: "uint"   },
      ],
      internalType: "struct PythStructs.Price",
      name: "price",
      type: "tuple",
    }],
    stateMutability: "view",
    type: "function",
  },
];

// -------------------- Solana (SDK) --------------------
async function readSolanaRows() {
  const conn = new Connection(RPC.sol, "confirmed");
  const now = Math.floor(Date.now()/1000);
  const rows = [];

  for (const f of FEEDS_SOL) {
    try {
      const info = await conn.getAccountInfo(new PublicKey(f.acc), "confirmed");
      if (!info) {
        rows.push({ net:"solana", kind:"Pyth", symbol:f.symbol, id:f.acc, status:"N/A", expo:null, priceUsd:null, confUsd:null, confBps:null, publishTimeUtc:null, ageSec:null, error:"account not found" });
        continue;
      }
      const p = parsePriceData(info.data); // official SDK

      const ageSec = p.publishTime ? (now - p.publishTime) : null;
      if (STALENESS > 0 && ageSec != null && ageSec > STALENESS) {
        rows.push({
          net:"solana", kind:"Pyth", symbol:f.symbol, id:f.acc,
          status: PriceStatus[p.status] ?? String(p.status),
          expo: p.exponent,
          priceUsd: Number(p.price).toFixed(6),
          confUsd:  Number(p.confidence).toExponential(8),
          confBps:  confBps(p.price, p.confidence).toFixed(6),
          publishTimeUtc: iso(p.publishTime),
          ageSec,
          note: `stale > ${STALENESS}s`,
        });
        continue;
      }

      rows.push({
        net:"solana", kind:"Pyth", symbol:f.symbol, id:f.acc,
        status: PriceStatus[p.status] ?? String(p.status),
        expo: p.exponent,
        priceUsd: Number(p.price).toFixed(6),
        confUsd:  Number(p.confidence).toExponential(8),
        confBps:  confBps(p.price, p.confidence).toFixed(6),
        publishTimeUtc: iso(p.publishTime),
        ageSec,
      });
    } catch (e) {
      rows.push({ net:"solana", kind:"Pyth", symbol:f.symbol, id:f.acc, status:"N/A", expo:null, priceUsd:null, confUsd:null, confBps:null, publishTimeUtc:null, ageSec:null, error:e.message || String(e) });
    }
  }

  return rows;
}

// -------------------- EVM (ethers) --------------------
async function readEvmRows(net, rpc, pythAddr, feedList) {
  const provider = new ethers.JsonRpcProvider(rpc);
  const c = new ethers.Contract(pythAddr, PYTH_ABI, provider);
  const now = Math.floor(Date.now()/1000);
  const rows = [];

  for (const {symbol, id} of feedList) {
    try {
      const px = await c.getPrice(id);
      const priceUsd = Number(px.price) * Math.pow(10, Number(px.expo));
      const confUsd  = Number(px.conf)  * Math.pow(10, Number(px.expo));
      const bps      = confBps(priceUsd, confUsd);

      rows.push({
        net: net, kind: "EVM", symbol, id,
        status: "N/A",
        expo: Number(px.expo),
        priceUsd: Number.isFinite(priceUsd) ? priceUsd.toFixed(6) : null,
        confUsd:  Number.isFinite(confUsd)  ? confUsd.toExponential(8) : null,
        confBps:  Number.isFinite(bps)      ? bps.toFixed(6) : null,
        publishTimeUtc: iso(px.publishTime),
        ageSec: now - Number(px.publishTime),
      });
    } catch (e) {
      // If nobody posted that feed recently, Pyth EVM reverts. Show a tidy row.
      rows.push({
        net: net, kind: "EVM", symbol, id,
        status: "UNAVAILABLE",
        expo: null,
        priceUsd: null,
        confUsd: null,
        confBps: null,
        publishTimeUtc: null,
        ageSec: null,
        note: "getPrice reverted (no recent post)",
      });
    }
  }

  return rows;
}

// -------------------- Output --------------------
function printRows(rows) {
  // unified columns
  const ordered = rows.map(r => ({
    net: r.net,
    kind: r.kind,
    symbol: r.symbol,
    id: r.id,
    status: r.status,
    expo: r.expo,
    priceUsd: r.priceUsd,
    confUsd: r.confUsd,
    confBps: r.confBps,
    publishTimeUtc: r.publishTimeUtc,
    ageSec: r.ageSec,
    ...(r.note ? { note: r.note } : {}),
    ...(r.error ? { error: r.error } : {}),
  }));
  ordered.sort((a,b) => (a.net.localeCompare(b.net) || (a.symbol ?? "").localeCompare(b.symbol ?? "")));
  if (pretty) console.table(ordered);
  else console.log(JSON.stringify(ordered, null, 2));
}

// -------------------- Main --------------------
(async function main(){
  const sol = await readSolanaRows();
  const base = await readEvmRows("base", RPC.base, PYTH_EVM.base, FEEDS_EVM.base);
  const bnb  = await readEvmRows("bnb",  RPC.bnb,  PYTH_EVM.bnb,  FEEDS_EVM.bnb);
  printRows([...sol, ...base, ...bnb]);
})().catch(e => { console.error(e); process.exit(1); });
