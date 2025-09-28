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
- Compare `deltaBps` against `OracleConfig.divergenceBps`.

This symmetric normalisation ensures we measure deviation relative to the larger price, avoiding asymmetric false positives when one feed drifts slightly above parity.

## Fail-Closed Behaviour
- When `deltaBps > divergenceBps`, the pool reverts with `Errors.OracleDiverged(deltaBps, divergenceBps)`.
- Reverts occur from `_readOracle`, so **quotes and swaps both fail** before touching inventory or fee state.
- HyperCore fallback paths (EMA, Pyth substitution) bypass the check by design—fail-closed semantics remain intact for degraded oracle regimes.

## Debug Instrumentation
When `FeatureFlags.debugEmit` is enabled we emit:
```
OracleDivergenceChecked(pythMid, hcMid, deltaBps, divergenceBps)
```
right before reverting. Use this to correlate on-chain rejects with observability dashboards and off-chain alerting.

## Operational Considerations
- Alerting: treat repeated `OracleDiverged` events as a signal that HyperCore is stale or skewed—auto-pause keepers should page operators once the threshold is crossed.
- Configuration hygiene: divergence caps tighter than HyperCore's expected short-term drift (typically 30–50 bps) will cause noisy reverts. Keep `divergenceBps` aligned with HyperCore venue slippage and Pyth update cadence.
- Guard rails: retain `OracleConfig.allowEmaFallback` for venues where HyperCore occasionally stalls—EMA reads remain subject to max-age enforcement and skip the divergence tripwire.
