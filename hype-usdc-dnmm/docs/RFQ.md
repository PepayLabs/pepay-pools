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

## Pre-trade Previews

Routers can now interrogate the pool's snapshot-backed preview surface before dispatching RFQs:

- `previewFees(uint256[] sizesBaseWad)` returns ask/bid fee ladders (bps) for arbitrary base sizes using the latest snapshot. The call is `view` and gas-light (~1k with a single size) because it replays the same fee pipeline that `swapExactIn` uses.
- `previewLadder(uint256 s0BaseWad)` is a convenience helper that outputs `[S0, 2S0, 5S0, 10S0]` sizes, clamp flags (AOMQ micro quotes), snapshot timestamp, and the mid used for the computation. If `s0BaseWad == 0` the pool derives S0 from `makerConfig.s0Notional`.
- Snapshots are updated automatically after every filled swap and may optionally be refreshed off-cycle via `refreshPreviewSnapshot`. When governance sets `previewMaxAgeSec > 0`, integrators SHOULD monitor `previewSnapshotAge()` and refresh when `age > previewMaxAgeSec`; with the zero-default configuration there is no staleness guard and the snapshots are advisory only.
- If `previewConfig.revertOnStalePreview == true` the preview calls revert with `PreviewSnapshotStale(age, maxAge)` once `previewMaxAgeSec > 0`. By default the flag is `false`, so routers can opt-in before roll-out. When enabled, routers should either trigger a refresh (if allowed) or fall back to `previewFeesFresh` when `enablePreviewFresh` is toggled on.
- Clamp flags signal that AOMQ is active and the reported fee already includes the micro-quote spread floor. Respecting the clamp avoids takers requesting depth beyond the configured min-notional.

> Tip: for RFQ slicing, run `previewFees` on the intended clip sizes, honour the clamp flags, then bundle the resulting fee ladders into the quote request that makers need to satisfy.
