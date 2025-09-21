// lifinity-profit-hardcoded.js
// Basic RPC only. No indexers. Hard-coded constants below.
// It finds the WSOL/USDC vaults owned by the Pool Authority,
// classifies large admin cash flows (sweeps/top-ups), and writes CSVs.
//
// Run: node lifinity-profit-hardcoded.js

import { Connection, PublicKey } from '@solana/web3.js';
import dayjs from 'dayjs';
import { createObjectCsvWriter as createCsvWriter } from 'csv-writer';

// ---------- HARD-CODED CONSTANTS ----------
const RPC_URL = 'https://api.mainnet-beta.solana.com';

// Lifinity SOL–USDC v2 Pool Authority (Solscan-labeled)
const POOL_AUTHORITY = new PublicKey('82nEEkdjAf2TsVVj189DgRdp7kkQ9Ghs4LqY1gcgbjxn');

// Canonical mints
const USDC_MINT = new PublicKey('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v');
const WSOL_MINT = new PublicKey('So11111111111111111111111111111111111111112');

// Time window (UTC). Hard-code as you like.
const START = dayjs('2025-07-01T00:00:00Z');
const END   = dayjs('2025-09-21T23:59:59Z');

// USD mark used ONLY to value WSOL admin sweeps (no oracles here)
const USD_PER_SOL_END = 150; // <-- set a reasonable mark for END timestamp

// Heuristic thresholds to consider a transfer "admin-sized"
const LARGE_USDC = 50_000;  // ≥$50k USDC out/in
const LARGE_SOL  = 300;     // ≥300 SOL out/in

// ---------- UTILS ----------
const conn = new Connection(RPC_URL, 'confirmed');
const TOKEN_PROGRAM_ID = new PublicKey('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');

// Basic helper
const inWindow = (blockTime) => {
  if (!blockTime) return false;
  const t = dayjs.unix(blockTime);
  return (t.isAfter(START) || t.isSame(START)) && (t.isBefore(END) || t.isSame(END));
};

const toUi = (raw, decimals) => raw / Math.pow(10, decimals || 0);

// Discover WSOL & USDC vault token accounts owned by the Pool Authority
async function findVaultsByOwner(ownerPk) {
  const resp = await conn.getParsedTokenAccountsByOwner(ownerPk, { programId: TOKEN_PROGRAM_ID });
  let usdcVault = null, wsolVault = null;
  for (const { pubkey, account } of resp.value) {
    const info = account.data.parsed.info;
    const mint = new PublicKey(info.mint);
    if (mint.equals(USDC_MINT)) usdcVault = new PublicKey(pubkey);
    if (mint.equals(WSOL_MINT)) wsolVault = new PublicKey(pubkey);
  }
  if (!usdcVault || !wsolVault) {
    throw new Error(`Could not find both vaults. Found: USDC=${usdcVault?.toString()} WSOL=${wsolVault?.toString()}`);
  }
  return { usdcVault, wsolVault };
}

// Page signatures back until we pass START
async function getSigsInWindow(addressPk) {
  const out = [];
  let before = undefined;
  const limit = 1000;
  while (true) {
    const sigs = await conn.getSignaturesForAddress(addressPk, { before, limit });
    if (sigs.length === 0) break;
    for (const s of sigs) if (inWindow(s.blockTime)) out.push(s.signature);
    const oldest = sigs[sigs.length - 1];
    if (oldest.blockTime && dayjs.unix(oldest.blockTime).isBefore(START)) break;
    before = oldest.signature;
  }
  return out;
}

// Extract SPL token transfers from parsed inner instructions
function extractTokenTransfers(parsedTx) {
  const meta = parsedTx.meta;
  if (!meta || !meta.innerInstructions) return [];
  const xfers = [];
  for (const inner of meta.innerInstructions) {
    for (const ix of inner.instructions || []) {
      // token program id may be base58 string on recent RPCs
      const pid = (ix.programId || ix.programIdIndex || {}).toString?.() || ix.programId;
      if (!pid) continue;
      if (pid.toString() !== TOKEN_PROGRAM_ID.toString()) continue;
      const p = ix.parsed;
      if (!p || !p.type || !p.type.startsWith('transfer')) continue;
      const info = p.info || {};
      // handle both transfer and transferChecked
      const amountRaw = Number(info.tokenAmount?.amount ?? info.amount ?? 0);
      const decimals = Number(info.tokenAmount?.decimals ?? (info.mint === USDC_MINT.toString() ? 6 : 9));
      xfers.push({
        source: info.source,
        destination: info.destination,
        mint: info.mint,
        amountUi: toUi(amountRaw, decimals),
        decimals,
        type: p.type
      });
    }
  }
  return xfers;
}

// Classify a tx as SWAP vs ADMIN (heuristic) based on vault in/out patterns
function classifyTxForVaults(xfers, usdcVaultStr, wsolVaultStr) {
  const hasUSDCOut = xfers.some(x => x.mint === USDC_MINT.toString() && x.source === usdcVaultStr);
  const hasUSDCIn  = xfers.some(x => x.mint === USDC_MINT.toString() && x.destination === usdcVaultStr);
  const hasWSOLOut = xfers.some(x => x.mint === WSOL_MINT.toString() && x.source === wsolVaultStr);
  const hasWSOLIn  = xfers.some(x => x.mint === WSOL_MINT.toString() && x.destination === wsolVaultStr);

  // Swap usually has opposite-direction transfers across the two vaults in the SAME tx
  const looksSwap = (hasUSDCOut && hasWSOLIn) || (hasWSOLOut && hasUSDCIn);

  if (looksSwap) return 'SWAP';
  if (hasUSDCOut || hasWSOLOut) return 'ADMIN_OUT';
  if (hasUSDCIn  || hasWSOLIn)  return 'ADMIN_IN';
  return 'OTHER';
}

async function main() {
  console.log('RPC:', RPC_URL);
  console.log('Window:', START.toISOString(), '→', END.toISOString());
  console.log('Pool Authority:', POOL_AUTHORITY.toString(), '(SOL–USDC v2)');

  const { usdcVault, wsolVault } = await findVaultsByOwner(POOL_AUTHORITY);
  const usdcVaultStr = usdcVault.toString();
  const wsolVaultStr = wsolVault.toString();
  console.log('USDC vault:', usdcVaultStr);
  console.log('WSOL vault:', wsolVaultStr);

  // Collect signatures for both vaults in window
  const sigsUSDC = await getSigsInWindow(usdcVault);
  const sigsWSOL = await getSigsInWindow(wsolVault);
  const sigSet = new Set([...sigsUSDC, ...sigsWSOL]);
  const signatures = [...sigSet];
  console.log('Tx count touching vaults in window:', signatures.length);

  // Fetch parsed transactions in batches
  const BATCH = 100;
  const events = [];
  for (let i = 0; i < signatures.length; i += BATCH) {
    const batch = signatures.slice(i, i + BATCH);
    const txs = await conn.getParsedTransactions(batch, { maxSupportedTransactionVersion: 0 });
    for (let j = 0; j < txs.length; j++) {
      const tx = txs[j];
      if (!tx || !tx.meta) continue;
      const sig = batch[j];
      const t = tx.blockTime ? dayjs.unix(tx.blockTime).toISOString() : null;

      const xfers = extractTokenTransfers(tx);
      // Only keep transfers that touch either vault
      const vaultXfers = xfers.filter(x => x.source === usdcVaultStr || x.destination === usdcVaultStr ||
                                           x.source === wsolVaultStr || x.destination === wsolVaultStr);
      if (vaultXfers.length === 0) continue;

      const kind = classifyTxForVaults(vaultXfers, usdcVaultStr, wsolVaultStr);

      // Record large admin flows (value heuristic)
      for (const x of vaultXfers) {
        const token = x.mint === USDC_MINT.toString() ? 'USDC' :
                      x.mint === WSOL_MINT.toString() ? 'WSOL' : 'OTHER';
        const direction =
          (x.source === usdcVaultStr || x.source === wsolVaultStr) ? 'OUT' :
          (x.destination === usdcVaultStr || x.destination === wsolVaultStr) ? 'IN' : 'NA';

        // Only record likely admin flows
        const big =
          (token === 'USDC' && x.amountUi >= LARGE_USDC) ||
          (token === 'WSOL' && x.amountUi >= LARGE_SOL);

        if ((kind === 'ADMIN_OUT' || kind === 'ADMIN_IN') && big) {
          events.push({
            time: t,
            signature: sig,
            kind,
            token,
            direction,
            amount: x.amountUi,
            usd_estimate: token === 'USDC' ? x.amountUi : x.amountUi * USD_PER_SOL_END,
            src: x.source,
            dst: x.destination
          });
        }
      }
    }
  }

  // Aggregate by month/direction/token
  const byMonth = new Map();
  let totalOut = 0, totalIn = 0;
  for (const e of events) {
    const month = dayjs(e.time).format('YYYY-MM');
    const key = `${month}:${e.kind}:${e.token}:${e.direction}`;
    const prev = byMonth.get(key) || { count: 0, amount: 0, usd: 0 };
    prev.count += 1;
    prev.amount += e.amount;
    prev.usd += e.usd_estimate;
    byMonth.set(key, prev);
    if (e.direction === 'OUT') totalOut += e.usd_estimate;
    if (e.direction === 'IN')  totalIn  += e.usd_estimate;
  }

  // Console report
  console.log('\n=== Admin Cash Flows (heuristic, large transfers only) ===');
  [...byMonth.entries()].sort().forEach(([k, v]) => {
    const [month, kind, token, dir] = k.split(':');
    console.log(`${month}  ${kind.padEnd(10)}  ${token}  ${dir}  x${v.count}  amount=${v.amount.toFixed(4)}  usd≈$${v.usd.toFixed(2)}`);
  });
  console.log(`\nTotal ADMIN OUT (usd est): $${totalOut.toFixed(2)}`);
  console.log(`Total ADMIN IN  (usd est): $${totalIn.toFixed(2)}\n`);

  // Write CSVs
  const csv1 = createCsvWriter({
    path: './lifinity_admin_flows_summary.csv',
    header: [
      { id: 'month', title: 'month' },
      { id: 'kind', title: 'kind' },
      { id: 'token', title: 'token' },
      { id: 'direction', title: 'direction' },
      { id: 'count', title: 'count' },
      { id: 'amount', title: 'amount' },
      { id: 'usd', title: 'usd_estimate' },
    ],
  });
  const rows = [...byMonth.entries()].map(([k, v]) => {
    const [month, kind, token, direction] = k.split(':');
    return { month, kind, token, direction, count: v.count, amount: v.amount, usd: Number(v.usd.toFixed(2)) };
  });
  await csv1.writeRecords(rows);

  const csv2 = createCsvWriter({
    path: './lifinity_admin_flows_events.csv',
    header: [
      { id: 'time', title: 'time' },
      { id: 'signature', title: 'signature' },
      { id: 'kind', title: 'kind' },
      { id: 'token', title: 'token' },
      { id: 'direction', title: 'direction' },
      { id: 'amount', title: 'amount' },
      { id: 'usd_estimate', title: 'usd_estimate' },
      { id: 'src', title: 'source' },
      { id: 'dst', title: 'destination' },
    ],
  });
  await csv2.writeRecords(events);

  console.log('Wrote ./lifinity_admin_flows_summary.csv');
  console.log('Wrote ./lifinity_admin_flows_events.csv');
  console.log('\nNote: This is a *cash-flow* view from vaults (basic RPC). For a full Fees vs MMP split you’d add per-swap fees and start/end snapshots.\n');
}

main().catch(e => { console.error(e); process.exit(1); });
