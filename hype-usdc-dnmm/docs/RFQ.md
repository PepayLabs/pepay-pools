---
title: "RFQ Integration"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# RFQ Integration

## Table of Contents
- [Overview](#overview)
- [EIP-712 Domain & Types](#eip-712-domain--types)
- [Verify & Swap Flow](#verify--swap-flow)
- [TTL & Slippage Guidance](#ttl--slippage-guidance)
- [Preview APIs & Determinism](#preview-apis--determinism)
- [Code & Test References](#code--test-references)

## Overview
`QuoteRFQ` enables off-chain signed quotes to settle against `DnmPool` under strict oracle guards. The contract wraps signature verification, swap execution, and telemetry emission for auditability; Core-4 adds router allowlisting (`setAggregatorRouter`) and LVR-aware fees that RFQ makers must account for in their pricing models.

## EIP-712 Domain & Types
- **Domain:** `name = "DNMM QuoteRFQ"`, `version = "1"`, `chainId = block.chainid`, `verifyingContract = QuoteRFQ` (`contracts/quotes/QuoteRFQ.sol:17-52`).
- **Type hash:**
  ```text
  Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt)
  ```
- Domain/type constants exposed via `hashQuote`, `hashTypedDataV4` (`contracts/quotes/QuoteRFQ.sol:159-175`).

## Verify & Swap Flow
1. **Taker validation:** `verifyAndSwap` checks caller matches `params.taker`, enforces aggregator allowlist when rebates enabled, and validates TTL (`contracts/quotes/QuoteRFQ.sol:94-112`).
2. **Signature check:** `hashTypedDataV4` + `_assertValidMakerSignature` support EOAs and ERC-1271 contracts (`contracts/quotes/QuoteRFQ.sol:205-233`).
3. **Pool quote:** Calls `DnmPool.quoteSwapExactIn` in strict mode with provided oracle data before routing to `swapExactIn`; rejects if pool output would be larger than maker quote (`QuoteOutputBelowPool`).
4. **Settlement:** Transfers tokens, returns leftovers on partial fills, emits `QuoteFilled` with actual fill amounts (`contracts/quotes/QuoteRFQ.sol:110-145`).

## TTL, MinOut & Slippage Guidance
- Default TTL: `maker.ttlMs = 300` ms (`config/parameters_default.json`). Clients SHOULD refresh quotes whenever on-chain latency exceeds ~250 ms so the 1 second preview freshness window is never breached.
- When `enableLvrFee` is set, the σ√Δt term already prices TTL into the surcharge. Avoid adding a second TTL premium off-chain—doing so would overcharge takers relative to the pool.
- **Size buckets & buffers (defaults):**
  - `≤ S0` (5k quote units): use ≥ 5 bps buffer beyond preview ladder output.
  - `S0 .. 5S0`: widen to ≥ 15 bps; expect AOMQ clamps when divergence triggers.
  - `> 5S0`: require explicit maker approval. If `enableSizeFee` is disabled, budget ~15 bps; otherwise blend in ladder quotes per rung.
- **MinOut calculation workflow:**
  1. Call `refreshPreviewSnapshot` (or use a swap that persists one) to ensure the snapshot is fresh.
  2. Invoke `previewLadder([S0, 2S0, 5S0, 10S0])` (or `previewFees` for arbitrary sizes) and select the rung matching your quote size.
  3. Compute `minAmountOut = previewAmountOut - slippage_buffer[rung]` (default buffers: `[5, 15, 15, 30]` bps; governance may tune for specific partners).
  4. Embed `minAmountOut` and TTL inside the signed payload; expire the quote client-side ≥50 ms before on-chain deadline.
- Ensure the executing address is allow-listed via `setAggregatorRouter` before enabling rebates; non-listed executors will observe the full fee with no 3 bps discount.

## Preview APIs & Determinism
- **`previewFees` / `previewLadder`:** Deterministic because the pool replays against the stored snapshot (`contracts/DnmPool.sol:1296-1416`).
- **Staleness handling:**
  - Core-4 defaults to `preview.maxAgeSec = 1` and `revertOnStalePreview = true`, so stale previews revert immediately (`PreviewSnapshotStale`).
  - Routers must refresh snapshots every loop; monitor `dnmm_snapshot_age_sec` < 1s.
- **Workflow recap:**
  1. Fetch ladder for `[S0, 2S0, 5S0, 10S0]` immediately after refreshing the snapshot.
  2. Apply the size-specific buffer (see above) and include the resulting `minAmountOut` in the signed payload.
  3. Record ladder parity logs (`PreviewLadderServed`) only when `featureFlags.debugEmit` is enabled; production paths keep events off for gas reasons.

## Code & Test References
- RFQ contract: `contracts/quotes/QuoteRFQ.sol:1-240`
- Interface: `contracts/interfaces/IQuoteRFQ.sol:1-140`
- Pool preview functions: `contracts/DnmPool.sol:1071-1416`
- Tests: `test/integration/Scenario_RFQ_AggregatorSplit.t.sol:18`, `test/integration/Scenario_Preview_AOMQ.t.sol:21`
