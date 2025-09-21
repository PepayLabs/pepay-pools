// read_lifinity_amm.mjs
import { Connection, PublicKey, Keypair } from "@solana/web3.js";
import * as anchor from "@coral-xyz/anchor";

const RPC = process.env.SOLANA_RPC ?? "https://api.mainnet-beta.solana.com";
const PROGRAM_ID = new PublicKey("2wT8Yq49kHgDzXuPxZSaeLaH1qbmGXtEyPy64bL7aD3c"); // lifinity_amm_v2
const POOL = new PublicKey("<POOL_PUBKEY>"); // <-- put a real AMM account here

const conn = new Connection(RPC, "confirmed");
const provider = new anchor.AnchorProvider(conn, new anchor.Wallet(Keypair.generate()), { commitment: "confirmed" });
anchor.setProvider(provider);

const idl = await anchor.Program.fetchIdl(PROGRAM_ID, provider);
const program = new anchor.Program(idl, PROGRAM_ID, provider);

// fetch a single AMM
const amm = await program.account.amm.fetch(POOL);
// config is an embedded struct
const c = amm.config;

// helper: map to EVM caps/windows
const D = BigInt(c.configDenominator.toString());
const subCapBps = Number((BigInt(c.oracleSubConfidenceLimit.toString()) * 10000n) / D);
const pcCapBps  = Number((BigInt(c.oraclePcConfidenceLimit.toString())  * 10000n) / D);

// choose your slot time policy (0.4–0.5s typical on Solana; pick conservative)
const SLOT_SEC = 0.4;
const mainAgeSec  = (Number(c.oracleMainSlotLimit) + Number(c.oracleMainSlotBuffer)) * SLOT_SEC;
const subAgeSec   = Number(c.oracleSubSlotLimit) * SLOT_SEC;
const pcAgeSec    = Number(c.oraclePcSlotLimit)  * SLOT_SEC;

console.log({
  pool: POOL.toBase58(),
  configDenominator: c.configDenominator.toString(),
  capsBps: { sub: subCapBps, pc: pcCapBps },
  maxAgeSec: { main: mainAgeSec, sub: subAgeSec, pc: pcAgeSec },
  rawSlots: {
    mainLimit: c.oracleMainSlotLimit.toString(),
    mainBuffer: c.oracleMainSlotBuffer.toString(),
    subLimit: c.oracleSubSlotLimit.toString(),
    pcLimit: c.oraclePcSlotLimit.toString(),
  },
  statusPolicy: c.oracleStatus.toString(),
  oracleType: c.oracleType.toString(),
});
