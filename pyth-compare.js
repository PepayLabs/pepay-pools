#!/usr/bin/env node
/**
 * pyth_all_chains.js
 * One-shot Pyth inspector for **Solana + Base (EVM) + BNB (EVM)** with a single run.
 * - Unified columns.
 * - Hard-coded Solana/EVM feeds (easy to edit below).
 * - Robust Solana decoder: auto-detects the correct AGG block (tries 0x90 and 0xD0).
 *
 * Usage:
 *   node pyth_all_chains.js --pretty
 *
 * Env (optional):
 *   SOLANA_RPC=...
 *   BASE_RPC=...
 *   BNB_RPC=...
 *   SLOT_SEC=0.4
 */

const { ethers } = require("ethers");
const { Connection, PublicKey } = require("@solana/web3.js");

// ---------- CONFIG ----------
const CFG = {
  rpc: {
    sol:  process.env.SOLANA_RPC ?? "https://api.mainnet-beta.solana.com",
    base: process.env.BASE_RPC   ?? "https://mainnet.base.org",
    bnb:  process.env.BNB_RPC    ?? "https://bsc-dataseed.binance.org",
  },
  pythEvm: {
    base: "0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a",
    bnb:  "0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594",
  },
  slotSec: parseFloat(process.env.SLOT_SEC ?? "0.4"),
};

// ---------- HARD-CODED FEEDS ----------
const FEEDS_SOL = [
  { label: "SOL/USD",  acc: "EPBJUVCmzvwkGPGcEuwKmXomfGt78Aozy6pj44x9xxDB" },
  { label: "USDC/USD", acc: "4VrjUJ7QyU3o5oxNE2LgnJDtryT7PfApD5Zw2PX8QPsh" },
  { label: "USDC/USD", acc: "978Mhamcn7XDkq21kvJWhUDPytJkYtkv8pqnXrUcpUxU" },
  { label: "USDC/USD", acc: "GCEitD54CdVVzUvvGVpB4rocCaY91LDHzeAVsD7bK8RZ" },
  { label: "USDT/USD", acc: "3ZDBff7jeQaksmGvmkRix36rU159EBDjYiPThvV8QVZM" },
];

const FEEDS_EVM = {
  base: [
    { label: "ETH/USD",  id: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace" },
    { label: "BTC/USD",  id: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43" },
    { label: "USDC/USD", id: "0x2fb245b9a84554a0f15aa123cbb5f64cd263b59e9a87d80148cbffab50c69f30" },
  ],
  bnb: [
    { label: "BNB/USD",  id: "0x2f95862b045670cd22bee3114c39763a4a08beeb663b145d283c31d7d1101c4f" },
    { label: "ETH/USD",  id: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace" },
  ],
};

// ---------- EVM ABI ----------
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

// ---------- Helpers ----------
const iso = s => new Date(Number(s)*1000).toISOString().replace('T',' ').replace('Z',' UTC');

const confBpsFromRawNum = (priceRaw, confRaw) => {
  const pAbs = Math.abs(Number(priceRaw));
  return pAbs === 0 ? 0 : (Number(confRaw) * 1e4) / pAbs;
};

const confBpsFromRawBI = (priceI, confU) => {
  const pAbs = priceI < 0n ? -priceI : priceI;
  if (pAbs === 0n) return 0;
  return Number((confU * 10000n) / pAbs);
};

const STATUS = { 0:"Unknown", 1:"Trading", 2:"Halted", 3:"Auction", 4:"Ignored" };

// ---------- Solana decode (auto-detect aggregate block) ----------
/*
 * We verify header, then try two candidate offsets for the AGG PriceInfo:
 *   cand A: base = 0x90  (price,conf,status,pubSlot)
 *   cand B: base = 0xD0  (price,conf,status,pubSlot)
 * Choose the candidate whose fields look sane.
 */
function decodePythHeader(buf) {
  if (buf.length < 0xF0) throw new Error("account too small");
  const magic = buf.readUInt32LE(0x00);
  const ver   = buf.readUInt32LE(0x04);
  const typ   = buf.readUInt32LE(0x08);
  if (magic !== 0xA1B2C3D4) throw new Error("bad magic");
  if (ver !== 2)            throw new Error("bad version");
  if (typ !== 3)            throw new Error("not PRICE");
  const expo   = buf.readInt32LE(0x14);
  const validU = buf.readBigUInt64LE(0x28);
  return { expo, validSlot: Number(validU) };
}

function readAggAt(buf, base) {
  try {
    const priceI = buf.readBigInt64LE(base + 0x00);
    const confU  = buf.readBigUInt64LE(base + 0x08);
    const status = buf.readUInt32LE   (base + 0x10);
    /* u32 corpAct at +0x14 (ignored) */
    const pubU   = buf.readBigUInt64LE(base + 0x18);
    return { priceI, confU, status, pubSlot: Number(pubU) };
  } catch { return null; }
}

function scoreCandidate(c, nowSlot, expo) {
  if (!c) return -1e9;
  let score = 0;

  // status plausible
  if (c.status >= 0 && c.status <= 4) score += 5; else score -= 5;

  // pubSlot plausible (0..nowSlot+small slack)
  if (Number.isFinite(c.pubSlot) && c.pubSlot >= 0 && c.pubSlot <= nowSlot + 10_000) score += 5; else score -= 5;

  // price magnitude sanity (avoid obvious garbage)
  const pAbs = c.priceI < 0n ? -c.priceI : c.priceI;
  // rough upper bound: 1e14 in raw units is already huge for expo -8
  if (pAbs > 0n && pAbs < 100000000000000n) score += 3; else score -= 3;

  // confBps plausibility
  const cb = confBpsFromRawBI(c.priceI, c.confU);
  if (Number.isFinite(cb) && cb >= 0 && cb <= 100000) score += 3; else score -= 3;

  // reward non-zero conf for non-peg expo (e.g. expo != 0, -8 is fine but conf zero is uncommon for SOL)
  if (c.confU !== 0n) score += 1;

  return score;
}

async function fetchSolRows() {
  const conn = new Connection(CFG.rpc.sol, "confirmed");
  const nowSlot = await conn.getSlot("confirmed");
  const rows = [];

  for (const {label, acc} of FEEDS_SOL) {
    try {
      const ai = await conn.getAccountInfo(new PublicKey(acc), "confirmed");
      if (!ai) continue;

      const buf = Buffer.from(ai.data);
      const { expo } = decodePythHeader(buf);

      // Try both blocks and pick the one that scores best
      const candA = readAggAt(buf, 0x90);
      const candB = readAggAt(buf, 0xD0);
      const scoreA = scoreCandidate(candA, nowSlot, expo);
      const scoreB = scoreCandidate(candB, nowSlot, expo);
      const d = scoreA >= scoreB ? candA : candB;

      // If still implausible, skip row
      if (scoreCandidate(d, nowSlot, expo) < 0) continue;

      const ageSlots = Math.max(0, nowSlot - d.pubSlot);
      const ageSec   = ageSlots * CFG.slotSec;
      const confBps  = confBpsFromRawBI(d.priceI, d.confU);

      rows.push({
        net: "solana", kind: "Solana",
        symbol: label, id: acc,
        status: STATUS[d.status] ?? String(d.status),
        priceRaw: d.priceI.toString(),          // exact
        expo: String(expo),
        conf: d.confU.toString(),               // exact
        confBps: confBps.toFixed(2),
        time: `slot ${d.pubSlot}`,
        ageSec: Number(ageSec.toFixed(1)),
      });
    } catch {
      continue;
    }
  }
  return rows;
}

// ---------- EVM runner ----------
async function fetchEvmRows(net, rpc, pythAddr, feedList) {
  const provider = new ethers.JsonRpcProvider(rpc);
  const c = new ethers.Contract(pythAddr, PYTH_ABI, provider);
  const now = Math.floor(Date.now()/1000);
  const rows = [];

  for (const {label, id} of feedList) {
    try {
      const p = await c.getPrice(id);
      rows.push({
        net, kind: "EVM",
        symbol: label, id,
        status: "N/A",
        priceRaw: String(p.price),
        expo: String(p.expo),
        conf: String(p.conf),
        confBps: confBpsFromRawNum(p.price, p.conf).toFixed(2),
        time: iso(p.publishTime),
        ageSec: now - Number(p.publishTime),
      });
    } catch {
      // Skip feeds that revert to keep table tidy.
      continue;
    }
  }
  return rows;
}

// ---------- Output ----------
function print(rows, pretty) {
  const ordered = rows.map(r => ({
    net: r.net,
    kind: r.kind,
    symbol: r.symbol,
    id: r.id,
    status: r.status,
    priceRaw: r.priceRaw,
    expo: r.expo,
    conf: r.conf,
    confBps: r.confBps,
    time: r.time,
    ageSec: r.ageSec,
  }));
  ordered.sort((a,b) => (a.net.localeCompare(b.net) || a.symbol.localeCompare(b.symbol)));
  if (pretty) console.table(ordered);
  else console.log(JSON.stringify(ordered, null, 2));
}

// ---------- Main ----------
(async function main(){
  const pretty = process.argv.includes("--pretty");

  const solRows  = await fetchSolRows();
  const baseRows = await fetchEvmRows("base", CFG.rpc.base, CFG.pythEvm.base, FEEDS_EVM.base);
  const bnbRows  = await fetchEvmRows("bnb",  CFG.rpc.bnb,  CFG.pythEvm.bnb,  FEEDS_EVM.bnb);

  print([...solRows, ...baseRows, ...bnbRows], pretty);
})().catch(e => { console.error(e); process.exit(1); });
