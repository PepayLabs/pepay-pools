# Divergence Policy

The pool only honours HyperCore spot quotes when a fresh Pyth reference price is available and the two sources agree within the configured tolerance.

## Freshness Requirements
- `OracleConfig.maxAgeSec` gates both HyperCore and Pyth sources.
- HyperCore mids with `ageSec == type(uint256).max` (unknown age) are treated as stale.
- Pyth results must succeed **and** have `max(ageSecHype, ageSecUsdc) <= maxAgeSec`.
- If Pyth is stale or unavailable we fall back to existing guards (EMA/Pyth-only legs) and skip the divergence check entirely.

## Symmetric Divergence Calculation
Given HyperCore mid `hc` and Pyth mid `pyth` (both 1e18 fixed-point):

- Let `hi = max(hc, pyth)` and `lo = min(hc, pyth)`.
- Compute `deltaBps = floor(((hi - lo) * 10_000) / hi)`.
- Compare `deltaBps` against the configured bands:
  - `OracleConfig.divergenceAcceptBps`: below this value the pool behaves normally.
  - `OracleConfig.divergenceSoftBps`: between accept and soft we charge an additional haircut fee.
  - `OracleConfig.divergenceHardBps`: above this value the pool hard-rejects (or defers to AOMQ when enabled).

This symmetric normalisation ensures we measure deviation relative to the larger price, avoiding asymmetric false positives when one feed drifts slightly above parity while still giving operators a graded response window.

## Fail-Closed Behaviour
- **Soft band (`accept < delta ≤ soft`)**: the pool emits `DivergenceHaircut(deltaBps, extraFeeBps)` and adds `haircutMinBps + haircutSlopeBps × (delta - accept)` to the fee (capped at `FeeConfig.capBps`).
- **Hard band (`delta > hard`)**: the pool emits `DivergenceRejected(deltaBps)` and reverts with `Errors.DivergenceHard(deltaBps, hardBps)` (future upgrades can route this into AOMQ micro-quotes instead of a hard fail).
- **Legacy behaviour**: when `enableSoftDivergence` is `false`, the historical `divergenceBps` guard remains in force and reverts with `Errors.OracleDiverged(deltaBps, divergenceBps)`.
- **All feeds dark/zero**: if HyperCore spot, EMA fallback, and Pyth reports all fail-or-zero simultaneously, the pool now reverts with `Errors.MidUnset()` instead of `Errors.OracleStale()`, signalling that no mid-price could be sourced (not merely that data was old).
- Reverts occur from `_readOracle`, so **quotes and swaps both fail** before touching inventory or fee state.
- HyperCore fallback paths (EMA, Pyth substitution) bypass the check by design—fail-closed semantics remain intact for degraded oracle regimes.

## Hysteresis & State

- The pool tracks a lightweight `SoftDivergenceState` (exposed via `getSoftDivergenceState()`) to avoid flapping when feeds oscillate around the accept threshold.
- Three consecutive healthy samples (`delta ≤ accept`) are required before the state toggles back to “inactive”; until then we continue to mark the pool as in soft divergence so downstream keepers/gateways can react consistently.
- `haircutMinBps` provides an immediate penalty the moment the soft band is entered, ensuring takers pay for skew even if the excess lasts a single block.

## Debug Instrumentation
When `FeatureFlags.debugEmit` is enabled we emit:
```
OracleDivergenceChecked(pythMid, hcMid, deltaBps, divergenceBps)
```
right before reverting. Use this to correlate on-chain rejects with observability dashboards and off-chain alerting.

## Operational Considerations
- Alerting: monitor both `DivergenceHaircut` (elevated fees) and `DivergenceRejected` (hard off) events. Auto-pause keepers should page operators once hard rejections trigger or haircuts persist.
- Configuration hygiene: tune `divergenceAccept/Soft/Hard` to match venue behaviour—typical settings (30 / 50 / 75 bps) provide a mild haircut window before disabling the book.
- Fee discipline: maintain `haircutMinBps + haircutSlopeBps × (soft - accept) < FeeConfig.capBps` to avoid accidental fee-cap saturation.
- Guard rails: retain `OracleConfig.allowEmaFallback` for venues where HyperCore occasionally stalls—EMA reads remain subject to max-age enforcement and skip the divergence tripwire.
- Guard rails: retain `OracleConfig.allowEmaFallback` for venues where HyperCore occasionally stalls—EMA reads remain subject to max-age enforcement and skip the divergence tripwire.
