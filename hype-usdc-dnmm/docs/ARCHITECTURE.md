# System Architecture

## Overview

The DNMM stack mirrors Lifinity v2 semantics while adapting to HyperEVM primitives:

- **`DnmPool`** – Core AMM vault controlling reserves, quoting, swap execution, fee state, inventory floors, pausing, and governance-controlled parameters.
- **`OracleAdapterHC`** – Reads HyperCore order-book precompiles for mid/bid/ask/EMA values and exposes normalized values to the pool.
- **`OracleAdapterPyth`** – Pulls Pyth HYPE/USD and USDC/USD feeds as fallback + divergence guard.
- **`QuoteRFQ`** (optional) – Verifies off-chain signed quotes and settles against the pool for makers that run in low-latency environments.

Supporting libraries provide fixed-point math, inventory deviation helpers, and partial-fill solving.

## Data Flow

1. **Quote request** – `quoteSwapExactIn` pulls the freshest HyperCore mid; if gates fail it walks the fallback tree (EMA → Pyth) with divergence checks.
2. **Fee computation** – Confidence proxy and inventory deviation feed into the DNMM fee surface with exponential decay back to base.
3. **Partial fill guard** – Before returning, the pool ensures post-trade reserves stay above floor thresholds; if not, it returns the maximal safe input amount.
4. **Swap execution** – `swapExactIn` reuses quote math, performs ERC20 transfers, updates fee state, emits telemetry events, and enforces reentrancy + deadline checks.
5. **Rebalancing** – Each swap calls `_checkAndRebalanceAuto` (respecting `recenterCooldownSec`) to refresh `targetBaseXstar` once drift > `recenterThresholdPct`; permissionless `rebalanceTarget()` provides a keeper fallback, and governance retains `setTargetBaseXstar` for manual overrides.

### Divergence Bands & Haircuts

- **Accept band** (`divergenceAcceptBps`): normal operations. When the soft-divergence feature flag is enabled, the pool records every sample in `softDivergenceState` while no extra fees are applied.
- **Soft band** (`divergenceSoftBps`): quotes remain online but the pool emits `DivergenceHaircut(deltaBps, extraFeeBps)` and adds `haircutMinBps + haircutSlopeBps × (delta - accept)` to the fee (capped by `FeeConfig.capBps`).
- **Hard band** (`divergenceHardBps`): emits `DivergenceRejected(deltaBps)` and reverts with `Errors.DivergenceHard(deltaBps, hardBps)`. Subsequent upgrades hook this into the AOMQ micro-liquidity path instead of a cold shutdown.
- **Hysteresis**: `getSoftDivergenceState()` exposes `(active, lastDeltaBps, healthyStreak)` so keepers can monitor recovery. Three consecutive healthy samples (`delta ≤ accept`) are required before the state toggles back to inactive, preventing alert flapping.

### Size-Aware Fee Curve

- Controlled via `FeeConfig.gammaSizeLinBps`, `gammaSizeQuadBps`, and `sizeFeeCapBps`, gated by the `enableSizeFee` feature flag.
- The pool normalises trade size by the maker-configured `s0Notional` (quote notional in WAD). `u = tradeNotional / s0Notional` produces a dimensionless multiplier.
- The additional surcharge is `gammaSizeLinBps × u + gammaSizeQuadBps × u²`, capped by `sizeFeeCapBps` and then by the global fee cap.
- Works symmetrically for base-in and quote-in trades (quote notional derived from the mid price). Previews, swaps, and RFQ settlement all reuse the same helper ensuring parity.

### BBO-Aware Floor (F05)

- Configuration lives in `MakerConfig` (`alphaBboBps`, `betaFloorBps`) and is gated by `featureFlags.enableBboFloor`.
- On every quote/swap the pool computes `floorDynamic = max(betaFloorBps, alphaBboBps * spreadBps / 10_000)`, where `spreadBps` comes from the HyperCore order book precompile.
- The final fee is clamped to `max(feeBps, floorDynamic)` after the size curve and soft-divergence haircuts run, but before downstream discounts. The result still honours `FeeConfig.capBps`.
- When the order book spread is unavailable (e.g., EMA/Pyth fallback), the absolute floor (`betaFloorBps`) is used so quotes never collapse to zero.
- Both swap execution and preview paths share the same helper, ensuring routers cannot undercut the configured minimum even when rebates are introduced in later upgrades.

### Inventory Tilt Upgrade (F06)

- Tilt parameters sit in `InventoryConfig` (`invTiltBpsPer1pct`, `invTiltMaxBps`, `tiltConfWeightBps`, `tiltSpreadWeightBps`) and are guarded by `featureFlags.enableInvTilt`.
- The instantaneous neutral inventory is computed as `x* = (Q + P × B) / (2P)` using live reserves; the deviation `Δ = B - x*` determines the tilt direction (positive = base-heavy).
- The raw adjustment is `tiltBase = |Δ|_bps × invTiltBpsPer1pct / 100`, then re-weighted by `(1 + tiltConfWeightBps × confBps / 10_000 + tiltSpreadWeightBps × spreadBps / 10_000)` and finally capped by `invTiltMaxBps`.
- Trades that worsen the deviation (e.g., base-heavy + base-in) receive a fee surcharge, while restorative trades are discounted symmetrically; adjustments never push below zero or above `FeeConfig.capBps`.
- The helper runs in both swap and preview paths so routers observe matching incentives, and all math is performed in-memory (no extra storage writes).

## Storage Layout

| Slot | Component | Notes |
|------|-----------|-------|
| 0    | Tokens/reserve state | Uses 128-bit packing for base/quote balances |
| 1    | Inventory config     | Floor, recenter thresholds, tilt coefficients |
| 2    | Oracle config        | Freshness windows, confidence caps, divergence tolerance |
| 3    | Fee config           | Base/alpha/beta/cap/decay parameters |
| 4    | Maker config         | On-chain S0 settings + BBO-aware floor coefficients |
| 5    | Guardians            | Governance + pauser |
| 6    | Fee state            | Last fee in bps + last update block |
| 7    | Cached mid           | Last mid used & timestamp for recentering |

## Contracts & Interfaces

- `IDnmPool` – Exposes read-only views plus swap/quote entrypoints.
- `IOracleAdapterHC` – Interface to HyperCore-specific reader contract.
- `IOracleAdapterPyth` – Interface to Pyth fallback/divergence contract.
- `IQuoteRFQ` – Optional verifying contract for off-chain quotes.

## Extensibility

- Additional oracles can be added by implementing the adapter interface and plugging into the pool's fallback chain.
- Hedging keeper integration is left as a v2 extension via events and read-only getters.
- Fee formulas allow parameterized exponent/coefficients; default matches spec but hook is general.
