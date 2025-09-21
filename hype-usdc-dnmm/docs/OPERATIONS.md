# Operations & Runbook

## Deployment Checklist
- [ ] Update `config/parameters_default.json` (or env-specific file) with approved values.
- [ ] Populate `config/oracle.ids.json` with live HyperCore + Pyth identifiers.
- [ ] `terragon-forge.sh script script/Deploy.s.sol --broadcast --rpc-url <RPC>`.
- [ ] Seed DNMM vault with balanced HYPE/USDC liquidity and call `sync()`.
- [ ] Set `targetBaseXstar` once post-deposit price drift ≥ recenter threshold.
- [ ] (Optional) Deploy `QuoteRFQ` and register maker signing keys.

## Guardians & Access Control
- `governance`: Multisig with timelock for parameter changes.
- `pauser`: Fast-path guardian (EOA or bot) empowered to pause swaps.
- `keeper` (optional): Address allowed to push recenter updates if automation desired.

## Monitoring
- Subscribe to `SwapExecuted`, `QuoteServed`, `ParamsUpdated`, `Paused`, `Unpaused`.
- Export metrics via indexer (see `docs/OBSERVABILITY.md`) and feed dashboards.
- Alert on:
  - Divergence rejections > 5 per block
  - Partial fills > 10% of notional within 1 hour
  - Oracle fallback usage spiking above baseline
  - Dynamic fee not decaying back toward base (potential stale state)

## Incident Response
1. Pause via `pause()` if swap correctness is at risk.
2. Diagnose root cause using event logs + external oracle health.
3. Update configs (`updateParams`) or push patched deploy script / adapter selectors.
4. Announce unpause after remediation and governance approval.

## References
- `docs/CONFIG.md` – Parameter management.
- `docs/ORACLE.md` – Oracle wiring + divergence settings.
- `SECURITY.md` – Threat model and audit notes.
- `RUNBOOK.md` – Full deployment flow.
