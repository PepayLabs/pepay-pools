# Oracle & Data Path

## HyperCore (Primary)
- **Config**: Parameters sourced from `config/parameters_default.json` → `oracle.hypercore.*`.
- **IDs**: Fill in `config/oracle.ids.json` (`assetIdHype`, `assetIdUsdc`, `marketIdHypeUsdc`, `precompile`).
- **Selectors**: Placeholder function selectors exist in `OracleAdapterHC.sol`; replace with official HyperEVM ABI once published.
- **Freshness**: `maxAgeSec` (Lifinity slots → seconds) and `stallWindowSec` enforce recency before swaps progress.
- **Confidence Proxy**: Confidence is blended via `conf_bps = max(w_spread·spread, w_sigma·sigma, w_pyth·pyth_conf)` with weights sourced from `config/parameters_default.json`. Components are clamped by the relevant cap (`confCapBpsSpot` / `confCapBpsStrict`).
- **Sigma EWMA**: `sigma` tracks realized volatility as an EWMA of per-block price deltas (λ ≈ 0.9). Sigma updates run at-most-once per block and seed from configured weights when `BLEND_ON` is enabled.

### Adapter Functions
- `readMidAndAge()` – Spot mid and age (seconds) from HyperCore.
- `readBidAsk()` – Best bid/ask plus computed spread bps.
- `readMidEmaFallback()` – EMA mid within stall window when spot is unavailable.

## Pyth (Fallback & Divergence)
- **Feeds**: HYPE/USD + USDC/USD price IDs referenced in `config/oracle.ids.json`.
- **Updates**: Supports push updates via calldata bundle (`readPythUsdMid(bytes updateData)`); also works with externally updated storage feeds.
- **Confidence**: Returns confidence bps per asset, combined using max() in the adapter.
- **Fallback Logic**: `_readOracle` takes Pyth mid when HyperCore fails gates and `allowEmaFallback` cannot recover. EMA wins priority when it is fresh; only if both spot and EMA are unusable does Pyth drive the swap.
- **Strict Cap Discipline**: Whenever Pyth contributes to the blended confidence (either as the primary source or within the EWMA blend), the strict cap (`confCapBpsStrict`) is enforced regardless of the requested mode.
- **Divergence Guard**: When HyperCore is primary and Pyth is fresh, swaps revert if absolute difference exceeds `divergenceBps`.

## Operational Notes
- Validate HyperCore precompile availability on target network; adjust gas expectations (read precompiles are typically constant).
- Ensure Pyth fee payer account is funded for on-chain updates (if using payload submission).
- Monitor `SwapExecuted` events for `reason = "PYTH" | "EMA"` to track fallback usage.
- Keep `config` files in sync with chain deployments; document any deviation in `RUNBOOK.md`.
