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

## TTL & Slippage Guidance
- Default TTL: `maker.ttlMs = 300` ms (`config/parameters_default.json`). Aggregators should request new quotes when TTL > 250 ms to avoid expiry and stay within 1-second preview freshness.
- **Size buckets:**
  - `≤ S0 (5k quote units)`: target slippage buffer ≥ 5 bps beyond preview ladder.
  - `S0 .. 5S0`: widen to 15 bps; expect potential AOMQ clamps when divergence active.
  - `> 5S0`: require explicit maker acknowledgement; if `enableSizeFee` is off, treat resulting fee as flat 15 bps.
- Always set `minAmountOut = previewAmountOut - slippage` using the latest `previewFees` / `previewLadder` outputs.
- Ensure the signing/exec address is allow-listed via `setAggregatorRouter` when rebates are active; non-listed executors will forfeit the 3 bps discount.

## Preview APIs & Determinism
- **`previewFees` / `previewLadder`:** Deterministic because the pool replays against the stored snapshot (`contracts/DnmPool.sol:1296-1416`).
- **Staleness handling:**
  - Core-4 defaults to `preview.maxAgeSec = 1` and `revertOnStalePreview = true`, so stale previews revert immediately (`PreviewSnapshotStale`).
  - Routers must refresh snapshots every loop; monitor `dnmm_snapshot_age_sec` < 1s.
- **Workflow:**
  1. Fetch ladder for `[S0, 2S0, 5S0, 10S0]`.
  2. Compute `minOut` by subtracting slippage buffer per bucket.
  3. Include `params.minAmountOut` + TTL in signed payload.
  4. Log ladder hash (`PreviewLadderServed`) for parity diagnostics when `debugEmit` is enabled.

## Code & Test References
- RFQ contract: `contracts/quotes/QuoteRFQ.sol:1-240`
- Interface: `contracts/interfaces/IQuoteRFQ.sol:1-140`
- Pool preview functions: `contracts/DnmPool.sol:1071-1416`
- Tests: `test/integration/Scenario_RFQ_AggregatorSplit.t.sol:18`, `test/integration/Scenario_Preview_AOMQ.t.sol:21`
