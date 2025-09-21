# Operations & Runbook

## Deployment Checklist

- [ ] Deploy `OracleAdapterHC` with correct asset/market IDs and the HyperCore precompile address.
- [ ] Deploy `OracleAdapterPyth` configured with Pyth contract + price IDs; seed fee payer.
- [ ] Deploy `DnmPool`, passing adapter addresses, governance, pauser, and initial configs.
- [ ] Seed the pool with balanced HYPE/USDC liquidity and set `targetBaseXstar`.
- [ ] (Optional) Deploy `QuoteRFQ` and register maker signing keys.

## Guardians & Access Control

- `governance`: Multisig with timelock for parameter changes.
- `pauser`: Fast-path guardian (EOA or bot) empowered to pause swaps.
- `keeper` (optional): Address allowed to push recenter updates.

## Monitoring

- Subscribe to `SwapExecuted`, `QuoteServed`, `ParamsUpdated`, `Paused`, `Unpaused`.
- Export metrics via indexer (see `observability/` spec) and feed dashboards.
- Alert on:
  - Divergence rejections > 5 per block
  - Partial fills > 10% of notional within 1 hour
  - Oracle fallback usage spiking above baseline

## Incident Response

1. Pause via `pause()` if swap correctness is at risk.
2. Diagnose root cause using event logs + external oracle health.
3. Update configs or push a patched deploy script.
4. Announce unpause after remediation.

## TODOs / Open Questions

- Confirm final HyperCore precompile selectors and ABI.
- Validate gas footprint of partial-fill solver against production limits.
- Decide on Hedging keeper deployment timeline (v2 scope).
