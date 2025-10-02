# Deployment Runbook

## Prerequisites
- Run `./setup.sh` to provision Node.js 20 + Foundry toolchain locally.
- Governance multisig and pauser EOAs funded with native HYPE for gas.
- Verified HyperCore asset/market identifiers and Pyth price IDs populated in `config/oracle.ids.json`.
- Tokens deployed on HyperEVM with initial protocol-owned liquidity available.
- Foundry dependencies installed (`terragon-forge.sh install` invocations as required).

## 1. Parameter Review
1. Validate `config/parameters_default.json` against latest risk sign-off.
2. Confirm token addresses/decimals in `config/tokens.hyper.json`.
3. Document any overrides in release notes and update `docs/CONFIG.md` if defaults evolve.

## 2. Contract Deployment
1. `terragon-forge.sh script script/Deploy.s.sol --broadcast --rpc-url <RPC>`
2. Record deployed addresses in the release sheet.
3. Assign governance/pauser roles via constructor parameters or `updateParams`.

## 3. Seeding Liquidity
1. Transfer HYPE and USDC into the pool contract proportionally to desired inventory.
2. Execute `sync()` to align internal reserves.
3. Trigger an initial price sample (small `swapExactIn` or `rebalanceTarget()` call) to seed `lastRebalancePrice`; use `setTargetBaseXstar` only if governance wants a custom override.
4. Set `recenterCooldownSec` via `setRecenterCooldownSec(<seconds>)` (120s recommended for majors, 180-300s for long-tail pairs) before enabling public swaps.

## 4. Smoke Tests
- Run `terragon-forge.sh test --match-test testSwapBaseForQuoteHappyPath`.
- Submit manual swaps with small size via fork RPC.
- Verify events through explorer or local indexer; confirm `feeBps` / `reason` values align with expectations.
- Trigger `refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""))` once swaps are live. Call `previewFees([1 ether, 2 ether])` and `previewLadder(0)` to confirm routers observe the same fee ordering (AOMQ clamp flags should be `false` in healthy conditions).

## 5. RFQ Enablement (Optional)
1. Deploy `QuoteRFQ` with maker key.
2. Fund taker allowances for HYPE/USDC.
3. Monitor `QuoteFilled` for partial fills and expiry behaviour.

## 6. Observability Bring-Up
- Connect indexer to `SwapExecuted`, `QuoteServed`, `ParamsUpdated`, `Paused`, `Unpaused`, `ManualRebalanceExecuted`, `RecenterCooldownSet`.
- Publish Grafana dashboard using metrics defined in `docs/OBSERVABILITY.md`.
- Persist test artifacts from `metrics/` (CSV/JSON) and `gas-snapshots.txt` into the monitoring pipeline for historical comparisons.
- Add preview health panels: `dnmm_preview_snapshot_age_sec`, `dnmm_preview_stale_reverts_total`, ladder ask/bid series by bucket, and clamp gauges. Alert when snapshot age > `previewMaxAgeSec` or stale reverts increase.
- Wire the parity freshness check after any long invariant run: execute `script/run_invariants.sh` (or `script/check_invariants_and_parity.sh`) and verify `reports/metrics/freshness_report.json` reports `status=pass` for all parity CSVs.
- Deploy `OracleWatcher` alongside the pool, configure thresholds, and run `scripts/watch_oracles.ts` to stream `OracleAlert` / `AutoPauseRequested`. Route `critical=true` alerts to on-call and wire the optional pause handler contract if using auto-pause. Track `lastRebalancePrice`, `lastRebalanceAt`, and cooldown adherence (time since last rebalance vs `recenterCooldownSec`) in dashboards/alerts.
- Publish Grafana annotations for DNMM params changes (`ParamsUpdated`) and auto-pause events; annotate any manual overrides (fee cap, floor, target) for future incident reviews.

### Shadow Bot Alert Playbook

| Alert Condition | First Response | Follow-up |
| --- | --- | --- |
| `dnmm_snapshot_age_sec > SNAPSHOT_MAX_AGE_SEC` for >2 loops | Trigger `refreshPreviewSnapshot(IDnmPool.OracleMode.Spot, bytes(""))` via keeper/governance. | Validate HyperCore midpoint is updating; check RPC metrics for error spikes. |
| `increase(dnmm_precompile_errors_total[5m]) > 0` | Fail over to a healthy RPC; confirm HyperCore precompile keys match prod mapping. | Inspect HyperCore status dashboards; pause routing if errors persist >10 minutes. |
| `dnmm_delta_bps{quantile="0.95"} > oracle.divergenceSoftBps` | Move routers to strict/EMA mode and widen price tolerance. | Examine DivergenceHaircut events, compare against CEX mid, consider pausing swaps if spread persists. |
| `dnmm_two_sided_uptime_pct < 98.5` during 15 min window | Review latest CSV probes for `clamp_flags`; rebalance inventory or widen caps. | Confirm keepers are refreshing previews and no on-chain clamp toggles are stuck. |
| Rising `dnmm_preview_stale_reverts_total` | Refresh snapshot manually and check `previewConfig()` parameters. | Reduce `INTERVAL_MS` or enable preview fresh mode if staleness is systemic. |

## 7. Timelock Operations
1. If enabling the timelock, queue `updateParams(ParamKind.Governance, abi.encode({timelockDelaySec: <seconds>}))` while delay is `0`.
2. For sensitive changes (`Oracle`, `Fee`, `Inventory`, `Maker`, `Feature`, `Aomq`):
   - `pool.queueParams(kind, abi.encode(newConfig))` – record `ParamsQueued(kind, eta, proposer, dataHash)`.
   - Wait until `block.timestamp ≥ eta`; monitors should confirm via Prometheus (`dnmm_params_eta_seconds`).
   - `pool.executeParams(kind)` – expect `ParamsExecuted` followed by `ParamsUpdated`.
3. To abort: `pool.cancelParams(kind)`; alerts should reset on `ParamsCanceled`.
4. Always archive the calldata + resulting events in the governance drive to preserve audit trail.

## 8. Autopause Handler Wiring
1. Deploy `DnmPauseHandler` with `(pool, governance, cooldownSec)` once watcher thresholds are signed off.
2. `pool.queueParams(ParamKind.Feature, ...)` to enable `enableAutoRecenter`/`enableSoftDivergence` if required for policy.
3. `governance` calls `pool.setPauser(address(handler))` to delegate pause authority.
4. `governance` calls `handler.setWatcher(address(watcher))` and (optionally) tunes cooldown via `handler.setCooldown(newCooldown)`. All changes emit events for dashboards.
5. Verify end-to-end by:
   - Forcing an over-age oracle sample → `OracleWatcher` emits `OracleAlert` + `AutoPauseRequested`.
   - Confirm `handler` emits `AutoPaused` and the pool logs `Paused(pauser)`.
   - Ensure `Unpaused` path remains governance-only.

## 9. Incident Response
- Use `pause()` to halt swaps on oracle divergence or vault issues.
- Investigate telemetry, adjust parameters through `updateParams` (emit new change logs).
- Unpause once post-mortem complete and governance approves.

## 10. Performance & Metric Validation
- Execute `forge test --match-path test/perf` to capture gas profiles (`metrics/gas_snapshots.csv`, `gas-snapshots.txt`) and burst reliability metrics (`metrics/load_burst_summary.csv`).
- Run `script/run_slither_ci.sh` to emit `reports/security/slither_findings.json`; review and clear any Medium/High severity issues before promotion.
- Ensure tuple/decimal sweep outputs (`metrics/tuple_decimal_sweep.csv`), fee dynamics series (`metrics/fee_B*.csv`), and preview ladders (`metrics/preview_ladder_*.csv` if generated) are reviewed before deployment to detect scaling regressions.
- After each perf sweep update `reports/gas/gas_report.json` and compare against budgets (quote ≤ 130k, swap ≤ 320k, previewFees ≤ 80k, previewLadder ≤ 250k, RFQ verify ≤ 470k) before committing.
- Run invariant suites with `script/run_invariants.sh` (defaults to an adaptive 20k run with sampling + idle guards) after cleaning `cache/invariant`; fall back to `FOUNDRY_INVARIANT_RUNS=2000 forge test --profile ci --match-path test/invariants` for quick smoke checks.
- When the long run executes, confirm `reports/invariants_run.json` shows planned vs executed parity and revert-rate ≤ 10%; escalate per `reports/ci/quality_gates_summary.json` if thresholds are breached.

## Appendices
- `docs/ORACLE.md` – HyperCore/Pyth wiring details.
- `docs/CONFIG.md` – Parameter file reference.
- `SECURITY.md` – Threat model and recommended audits.
