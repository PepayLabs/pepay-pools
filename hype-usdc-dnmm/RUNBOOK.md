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

## 4. Smoke Tests
- Run `terragon-forge.sh test --match-test testSwapBaseForQuoteHappyPath`.
- Submit manual swaps with small size via fork RPC.
- Verify events through explorer or local indexer; confirm `feeBps` / `reason` values align with expectations.

## 5. RFQ Enablement (Optional)
1. Deploy `QuoteRFQ` with maker key.
2. Fund taker allowances for HYPE/USDC.
3. Monitor `QuoteFilled` for partial fills and expiry behaviour.

## 6. Observability Bring-Up
- Connect indexer to `SwapExecuted`, `QuoteServed`, `ParamsUpdated`, `Paused`, `Unpaused`.
- Publish Grafana dashboard using metrics defined in `docs/OBSERVABILITY.md`.
- Persist test artifacts from `metrics/` (CSV/JSON) and `gas-snapshots.txt` into the monitoring pipeline for historical comparisons.
- Wire the parity freshness check after any long invariant run: execute `script/run_invariants.sh` (or `script/check_invariants_and_parity.sh`) and verify `reports/metrics/freshness_report.json` reports `status=pass` for all parity CSVs.
- Deploy `OracleWatcher` alongside the pool, configure thresholds, and run `scripts/watch_oracles.ts` to stream `OracleAlert` / `AutoPauseRequested`. Route `critical=true` alerts to on-call and wire the optional pause handler contract if using auto-pause.

## 7. Incident Response
- Use `pause()` to halt swaps on oracle divergence or vault issues.
- Investigate telemetry, adjust parameters through `updateParams` (emit new change logs).
- Unpause once post-mortem complete and governance approves.

## 8. Performance & Metric Validation
- Execute `forge test --match-path test/perf` to capture gas profiles (`metrics/gas_snapshots.csv`, `gas-snapshots.txt`) and burst reliability metrics (`metrics/load_burst_summary.csv`).
- Run `script/run_slither_ci.sh` to emit `reports/security/slither_findings.json`; review and clear any Medium/High severity issues before promotion.
- Ensure tuple/decimal sweep outputs (`metrics/tuple_decimal_sweep.csv`) and fee dynamics series (`metrics/fee_B*.csv`) are reviewed before deployment to detect scaling regressions.
- After each perf sweep update `reports/gas/gas_report.json` and compare against budgets (quote ≤ 90k, swap ≤ 200k, rfq ≤ 400k) before committing.
- Run invariant suites with `script/run_invariants.sh` (defaults to an adaptive 20k run with sampling + idle guards) after cleaning `cache/invariant`; fall back to `FOUNDRY_INVARIANT_RUNS=2000 forge test --profile ci --match-path test/invariants` for quick smoke checks.
- When the long run executes, confirm `reports/invariants_run.json` shows planned vs executed parity and revert-rate ≤ 10%; escalate per `reports/ci/quality_gates_summary.json` if thresholds are breached.

## Appendices
- `docs/ORACLE.md` – HyperCore/Pyth wiring details.
- `docs/CONFIG.md` – Parameter file reference.
- `SECURITY.md` – Threat model and recommended audits.
