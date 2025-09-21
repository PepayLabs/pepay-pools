// read_amm_manual_to_json.mjs
// Lifinity v2 AMM scanner (manual decode, hard-coded token symbols, no network).
// Usage:
//   node read_amm_manual_to_json.mjs --pretty
//   node read_amm_manual_to_json.mjs --only-live --limit 25 --out lifinity_pools.json --pretty
//
// Env:
//   SOLANA_RPC=https://api.mainnet-beta.solana.com
//   LIFINITY_PROGRAM_ID=2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c
//   SLOT_SEC=0.4   (seconds per slot; 0.4–0.5 typical)

import { Connection, PublicKey } from "@solana/web3.js";
import bs58 from "bs58";
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";

// ---------- config / CLI ----------
const RPC = process.env.SOLANA_RPC ?? "https://api.mainnet-beta.solana.com";
const PROGRAM_ID = new PublicKey(
  process.env.LIFINITY_PROGRAM_ID ?? "2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c"
);
const SLOT_SEC = parseFloat(process.env.SLOT_SEC ?? "0.4"); // slot→seconds

const args = process.argv.slice(2);
const getArg = (flag, dflt) => {
  const i = args.indexOf(flag);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};
const OUT     = getArg("--out", "lifinity_pools_oracle_config.json");
const LIMIT   = parseInt(getArg("--limit", "0"), 10) || 0;
const PRETTY  = args.includes("--pretty");
const ONLY_LIVE = args.includes("--only-live"); // filter to initialized & not frozen

// ---- hard-coded mint → metadata (extend anytime) ----
const TOKENS = new Map(Object.entries({
  "So11111111111111111111111111111111111111112": { symbol: "wSOL", name: "Wrapped SOL", decimals: 9 },
  "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v": { symbol: "USDC", name: "USD Coin", decimals: 6 },
  "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB": { symbol: "USDT", name: "Tether USD", decimals: 6 },
  "mSoLzYCxHdYgdzU16g5QSh3i5K3z3KZK7ytfqcJm7So":   { symbol: "mSOL", name: "Marinade Staked SOL", decimals: 9 },
  "7dHbWXmci3dT8UFYWYZweBLXgycu7Y3iL6trKn1Y7ARj": { symbol: "stSOL", name: "Lido Staked SOL", decimals: 9 },
  "4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R": { symbol: "RAY",  name: "Raydium", decimals: 6 },
  "orcaEKTdK7LKz57vaAYr9QeNsVEPfiu6QeMU1kektZE":   { symbol: "ORCA", name: "Orca", decimals: 6 },
  "DezXAZ8z7PnrnRJjz3wXBoRgixCa6xjnB7YaB1pPB263": { symbol: "BONK", name: "Bonk", decimals: 5 },
  "7vfCXTUXx5WJV5JADk17DUJ4ksgau7utNKj4b963voxs": { symbol: "WETH", name: "WETH (Wormhole)", decimals: 8 },
  "JUPyiwrYJFskUPiHa7hkeR8VUtAeFoSYbKedZNsDvCN":  { symbol: "JUP",  name: "Jupiter", decimals: 6 },
  "7kbnvuGBxxj8AG9qp8Scn56muWGaRaFqxg1FsRp3PaFT": { symbol: "USDH", name: "Hubble USD", decimals: 6 },
  "bSo13r4TkiE4KumL71LsHTPpL2euBYLFx6h9HP3piy1":  { symbol: "bSOL", name: "BlazeStake Staked SOL", decimals: 9 },
  "MNDEFzGvMt87ueuHvVU9VcTqsAP5b3fTGPsHuuPA5ey":   { symbol: "MNDE", name: "Marinade", decimals: 9 },
  "J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn":  { symbol: "JTO",  name: "Jito", decimals: 9 },
  "hntyVP6YFm1Hg25TN9WGLqM12b8TQmcknKrdu1oxWux":   { symbol: "HNT",  name: "Helium", decimals: 8 },
  "WENWENvqqNya429ubCdR81ZmD69brwQaaBYY6p3LCpk":   { symbol: "WEN",  name: "Wen", decimals: 5 },
}));

// ---------- helpers ----------
const disc = bs58.encode(
  createHash("sha256").update("account:Amm").digest().subarray(0, 8)
);

const u64 = (b, o) => b.readBigUInt64LE(o);
const i64 = (b, o) => b.readBigInt64LE(o);
const u8  = (b, o) => b.readUInt8(o);
const pubStr = (b, o) => new PublicKey(b.subarray(o, o + 32)).toBase58();

const toNum = (v) => Number(v.toString());
const bps   = (num, den) => Number((num * 10000n) / (den || 1n));

function enrichToken(mint) {
  const meta = TOKENS.get(mint);
  if (meta) {
    return {
      mint,
      symbol: meta.symbol,
      name: meta.name ?? null,
      decimals: Number.isFinite(meta.decimals) ? meta.decimals : null,
      logoURI: null,
      supply: null,
    };
  }
  return { mint, symbol: null, name: null, decimals: null, logoURI: null, supply: null };
}

// decode Amm header (everything before `config`)
function decodeAmmHeader(buf) {
  let p = 8; // skip 8-byte discriminator

  const initializerKey                = pubStr(buf, p); p += 32;
  const initializerDepositTokenAccount= pubStr(buf, p); p += 32;
  const initializerReceiveTokenAccount= pubStr(buf, p); p += 32;

  const initializerAmount = u64(buf, p); p += 8;
  const takerAmount       = u64(buf, p); p += 8;

  const isInitialized = !!u8(buf, p); p += 1;
  const bumpSeed      = u8(buf, p);   p += 1;
  const freezeTrade   = u8(buf, p);   p += 1;
  const freezeDeposit = u8(buf, p);   p += 1;
  const freezeWithdraw= u8(buf, p);   p += 1;

  const baseDecimals  = u8(buf, p);   p += 1;

  const tokenProgramId = pubStr(buf, p); p += 32;
  const tokenAAccount  = pubStr(buf, p); p += 32;
  const tokenBAccount  = pubStr(buf, p); p += 32;
  const poolMint       = pubStr(buf, p); p += 32;
  const tokenAMint     = pubStr(buf, p); p += 32;
  const tokenBMint     = pubStr(buf, p); p += 32;
  const feeAccount     = pubStr(buf, p); p += 32;
  const oracleMainAccount = pubStr(buf, p); p += 32;
  const oracleSubAccount  = pubStr(buf, p); p += 32;
  const oraclePcAccount   = pubStr(buf, p); p += 32;

  // AmmFees (8 u64)
  p += 8 * 8;

  // AmmCurve (u8 + u64)
  const curveType       = u8(buf, p); p += 1;
  const curveParameters = u64(buf, p); p += 8;

  return {
    p, // offset of AmmConfig
    header: {
      initializerKey,
      initializerDepositTokenAccount,
      initializerReceiveTokenAccount,
      initializerAmount: initializerAmount.toString(),
      takerAmount: takerAmount.toString(),
      isInitialized,
      bumpSeed,
      freezeTrade, freezeDeposit, freezeWithdraw,
      baseDecimals,
      tokenProgramId,
      tokenAAccount, tokenBAccount,
      poolMint,
      tokenAMint, tokenBMint,
      feeAccount,
      oracleMainAccount, oracleSubAccount, oraclePcAccount,
      curveType, curveParameters: curveParameters.toString()
    }
  };
}

// decode AmmConfig (exact order from your IDL)
function decodeConfig(buf, start) {
  let p = start;

  const lastPrice          = u64(buf, p); p += 8;
  const lastBalancedPrice  = u64(buf, p); p += 8;
  const denom              = u64(buf, p); p += 8;

  // volumeX, volumeY, volumeXInY, depositCap, regressionTarget, oracleType, oracleStatus
  p += 8 * 7;

  const oracleMainSlotLimit      = u64(buf, p); p += 8;
  const oracleSubConfidenceLimit = u64(buf, p); p += 8;
  const oracleSubSlotLimit       = u64(buf, p); p += 8;
  const oraclePcConfidenceLimit  = u64(buf, p); p += 8;
  const oraclePcSlotLimit        = u64(buf, p); p += 8;

  // stdSpread, stdSpreadBuffer, spreadCoefficient
  p += 8 * 3;

  const priceBufferCoin = i64(buf, p); p += 8;
  const priceBufferPc   = i64(buf, p); p += 8;
  const rebalanceRatio  = u64(buf, p); p += 8;
  const feeTrade        = u64(buf, p); p += 8;
  const feePlatform     = u64(buf, p); p += 8;

  const oracleMainSlotBuffer = u64(buf, p); p += 8;

  return {
    denom,
    oracleMainSlotLimit,
    oracleMainSlotBuffer,
    oracleSubConfidenceLimit,
    oracleSubSlotLimit,
    oraclePcConfidenceLimit,
    oraclePcSlotLimit,
    priceBufferCoin, priceBufferPc,
    rebalanceRatio, feeTrade, feePlatform
  };
}

(async function main() {
  const conn = new Connection(RPC, "confirmed");

  const accounts = await conn.getProgramAccounts(PROGRAM_ID, {
    commitment: "confirmed",
    filters: [{ memcmp: { offset: 0, bytes: disc } }],
  });

  if (!accounts.length) {
    console.log("No Amm accounts found for", PROGRAM_ID.toBase58());
    return;
  }

  const out = [];
  let count = 0;

  for (const { pubkey, account } of accounts) {
    if (LIMIT && count >= LIMIT) break;
    const buf = Buffer.from(account.data);

    try {
      const { p: cfgStart, header } = decodeAmmHeader(buf);

      if (ONLY_LIVE) {
        if (!header.isInitialized) continue;
        if (header.freezeTrade || header.freezeDeposit || header.freezeWithdraw) continue;
      }

      const cfg = decodeConfig(buf, cfgStart);

      const capSubBps = bps(cfg.oracleSubConfidenceLimit, cfg.denom);
      const capPcBps  = bps(cfg.oraclePcConfidenceLimit,  cfg.denom);

      const mainAgeSec = (toNum(cfg.oracleMainSlotLimit) + toNum(cfg.oracleMainSlotBuffer)) * SLOT_SEC;
      const subAgeSec  = toNum(cfg.oracleSubSlotLimit) * SLOT_SEC;
      const pcAgeSec   = toNum(cfg.oraclePcSlotLimit)  * SLOT_SEC;

      const tokA = enrichToken(header.tokenAMint);
      const tokB = enrichToken(header.tokenBMint);
      const lp   = enrichToken(header.poolMint);

      const symA = tokA.symbol ?? tokA.mint.slice(0, 4);
      const symB = tokB.symbol ?? tokB.mint.slice(0, 4);
      const pair = `${symA}/${symB}`;

      out.push({
        amm: pubkey.toBase58(),
        pair,
        tokens: {
          A: tokA,
          B: tokB,
          poolMint: lp,
          tokenAAccount: header.tokenAAccount,
          tokenBAccount: header.tokenBAccount,
          feeAccount: header.feeAccount
        },
        oracles: {
          main: header.oracleMainAccount,
          sub:  header.oracleSubAccount,
          pc:   header.oraclePcAccount
        },
        flags: {
          isInitialized: header.isInitialized,
          freezeTrade: header.freezeTrade,
          freezeDeposit: header.freezeDeposit,
          freezeWithdraw: header.freezeWithdraw
        },
        oracleConfig: {
          capBpsSub: capSubBps,
          capBpsPc:  capPcBps,
          maxAgeSecMain: mainAgeSec,
          maxAgeSecSub:  subAgeSec,
          maxAgeSecPc:   pcAgeSec,
          allowEmaFallback: true
        },
        raw: {
          denom: cfg.denom.toString(),
          slots: {
            mainLimit:   cfg.oracleMainSlotLimit.toString(),
            mainBuffer:  cfg.oracleMainSlotBuffer.toString(),
            subLimit:    cfg.oracleSubSlotLimit.toString(),
            pcLimit:     cfg.oraclePcSlotLimit.toString()
          },
          priceBufferCoin: cfg.priceBufferCoin.toString(),
          priceBufferPc:   cfg.priceBufferPc.toString(),
          rebalanceRatio:  cfg.rebalanceRatio.toString(),
          feeTrade:        cfg.feeTrade.toString(),
          feePlatform:     cfg.feePlatform.toString()
        }
      });

      count++;
    } catch {
      // silently skip if layout mismatch
    }
  }

  await writeFile(OUT, PRETTY ? JSON.stringify(out, null, 2) : JSON.stringify(out));
  console.log(`Wrote ${out.length} pool records → ${OUT}`);
  if (ONLY_LIVE) console.log("(filtered to only live pools)");
})();
