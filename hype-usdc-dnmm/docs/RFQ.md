# RFQ Path

## Overview

`QuoteRFQ` enables low-latency makers to serve signed quotes off-chain while enforcing expiry, salt uniqueness, and signature verification on-chain. The contract coordinates token movement and forwards execution to `DnmPool` once a taker submits a validated quote.

## Flow

1. Maker signs `QuoteParams` (taker, amountIn, minAmountOut, side, expiry, salt) using the RFQ EOA.
2. Taker approves `QuoteRFQ` to pull the input token and submits the signature + params + oracle calldata.
3. `QuoteRFQ` verifies expiry and salt, pulls input tokens, approves the pool, and calls `swapExactIn`.
4. Any unused input (partial fill) is refunded and output tokens are forwarded to the taker.

## Security Notes

- Salts are single-use to avoid replay. A per-quote GUID or monotonic counter is recommended.
- Signatures include `chainId` and pool address to prevent cross-chain reuse.
- Maker key rotation uses `setMakerKey`, gateable by `owner` (set to deployer by default).
- Monitor `QuoteFilled` events with `salt` indexing to detect anomalies.

## Integration Checklist

- The maker service should track outstanding salts and invalidate old quotes at expiry.
- Takers must approve `QuoteRFQ` for either HYPE or USDC prior to calling `verifyAndSwap`.
- `oracleData` should include the same payload used in on-chain swaps (e.g., Pyth price update bundle).
- For multi-sig key rotation, stage a new key via governance tooling before switching the signer live.
