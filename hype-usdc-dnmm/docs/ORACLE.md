# Oracle & Data Path

## HyperCore (Primary)

- **Source**: HyperEVM read precompile exposing Hyperliquid HyperCore order-book + oracle snapshots.
- **IDs**: Configure `assetIdHype`, `assetIdUsdc`, and `marketIdHypeUsdc` constants at deployment time.
- **Freshness**: `maxAgeSec` and `stallWindowSec` enforce strict timing; we reject stale or stalled data.
- **Spread Cap**: Derived from bid/ask; when spread exceeds `confCapBpsSpot`, we either switch to EMA or fallback to Pyth.

### Functions

- `readMidAndAge()` – Returns `(mid, ageSeconds)` using top-of-book quotes.
- `readBidAsk()` – Returns `(bid, ask, spreadBps)`; `spreadBps` is used for the confidence proxy.
- `readMidEmaFallback()` – Uses the precompile EMA exposure when spot is unavailable but EMA is within the stall window.

## Pyth (Fallback & Divergence)

- **Feeds**: HYPE/USD and USDC/USD price feeds aggregated to a HYPE/USDC synthetic mid.
- **Updates**: Contracts support push updates via calldata or rely on a writer contract that updates storage.
- **Confidence**: Pyth-provided confidence intervals are repurposed as an additional cap for `confBps`.

### Functions

- `readPythUsdMid()` – Grabs the latest USD-margined prices and metadata (age + confidence).
- `computePairMid()` – Returns the cross rate HYPE/USDC using 1e18 fixed-point math.

## Divergence Flow

1. Pull HyperCore mid + metadata.
2. Pull Pyth mid if HyperCore passes freshness but we still want divergence check.
3. Compute `absDiffBps` between HyperCore and Pyth mid.
4. If `absDiffBps > divergenceBps`, return a rejection flag to the pool; the pool emits a `SwapExecuted` event with `partial = true` and `reason = Divergence`.

## Confidence Proxy

- Base component: `spreadBps` from the primary oracle.
- Optional overlay: short-window sigma posted by a keeper (not included in v1).
- Caps: `confCapBpsSpot` for quotes, `confCapBpsStrict` for swaps under tight risk.

## Operational Checklist

- Confirm precompile addresses on HyperEVM release network (mainnet/testnet differ!).
- Verify Pyth price IDs and ensure fee authority has the ability to fund updates.
- Monitor `SwapExecuted` events for `reason = OracleFallback` / `reason = Divergence` spikes.
