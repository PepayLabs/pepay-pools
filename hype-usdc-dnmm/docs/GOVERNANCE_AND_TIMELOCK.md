---
title: "Governance & Timelock"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Governance & Timelock

## Table of Contents
- [Roles](#roles)
- [Parameter Update Process](#parameter-update-process)
- [Guard Rails](#guard-rails)
- [Sensitive vs Non-Sensitive Params](#sensitive-vs-non-sensitive-params)
- [Operational Examples](#operational-examples)
- [Events & Errors](#events--errors)
- [Tests](#tests)

## Roles
- **governance:** Primary controller; can queue/execute/cancel parameter updates (`contracts/DnmPool.sol:606-649`).
- **pauser:** Emergency operator; can pause/unpause without timelock when divergence/spread issues (`contracts/DnmPool.sol:615`).
- **treasury:** Receives fees/rebates where applicable (see `IDnmPool.Guardians`).

## Parameter Update Process
1. **Queue (optional):**
   ```solidity
   eta = pool.queueParams(kind, abi.encode(newConfig));
   ```
   Requires `governance.timelockDelaySec > 0`. Returns ETA timestamp (`contracts/DnmPool.sol:616`).
2. **Execute:** After ETA reached, call `executeParams(kind)` to apply config (`contracts/DnmPool.sol:636`).
3. **Immediate update:** If timelock = 0, use `updateParams(kind, data)` for atomic change (`contracts/DnmPool.sol:606`).
4. **Cancel:** `cancelParams(kind)` clears pending queue entries (`contracts/DnmPool.sol:649`).

## Guard Rails
- `_requiresTimelock` forces preview & governance changes through queue even when delay is `0` (hard-coded) to avoid bricking preview pipeline (`contracts/DnmPool.sol:747-752`).
- `_applyParamUpdate` validates invariants:
  - Oracle configs must respect `divergenceSoftBps >= divergenceAcceptBps` or zero (`contracts/DnmPool.sol:669`).
  - Feature flags sanitized; unknown kinds revert with `Errors.InvalidParamKind()`.
- Timelock enforcement: if delay set and no queue entry exists, `Errors.TimelockRequired()` reverts immediate update (`contracts/lib/Errors.sol:24`).

## Sensitive vs Non-Sensitive Params
Category | Sensitivity | Notes
--- | --- | ---
Oracle | **High** | Affects pricing; require queue even if delay zero.
Fee | Medium | Can update atomically when timelock zero; consider queue in prod.
Inventory | Medium | Changes floors, targets; queue recommended with announcement.
Maker | Medium | TTL/S0 adjustments; coordinate with routers.
Feature | High | Enables pipeline components; queue + canary before enable.
AOMQ | Medium | Impacts degraded behavior; queue if changing `minQuoteNotional`.
Preview | **High** | Forced queue via `_requiresTimelock`.
Governance | **High** | Only accessible via queue.

## Operational Examples
- **Enable auto recenter with 24h timelock:**
  1. Set `governance.timelockDelaySec = 86400` via immediate update (allowed because delay currently 0).
  2. Queue feature flag payload enabling `enableAutoRecenter`.
  3. After ETA, call `executeParams` and confirm `TargetBaseXstarUpdated` events.
- **Emergency disable size fee:**
  1. Because timelock zero, call `updateParams(ParamKind.Feature, encodedFlags)` to toggle off.
  2. Verify `featureFlags.enableSizeFee` false in `feature_status.md` and preview parity tests.

## Events & Errors
Signal | Purpose
--- | ---
`ParamsQueued(bytes32 label, uint40 eta)` | Emitted when queue entry stored (`contracts/DnmPool.sol:612`).
`ParamsExecuted(bytes32 label)` | Fired on execute success (`contracts/DnmPool.sol:641`).
`ParamsCancelled(bytes32 label)` | Emitted when pending entry removed (`contracts/DnmPool.sol:653`).
`Errors.TimelockRequired()` | Thrown when immediate update attempted but timelock > 0 (`contracts/lib/Errors.sol:24`).
`Errors.InvalidParamKind()` | Thrown on unknown `ParamKind` (`contracts/lib/Errors.sol:20`).

## Tests
- Governance queue: `test/unit/DnmPool_GovernanceTimelock.t.sol:15`.
- Feature flip coverage: `test/unit/FeatureFlagsTest.t.sol` (ensure doc update if absent).
- Negative cases: `test/integration/Scenario_TimestampGuards.t.sol:24` ensures ETA enforcement.
