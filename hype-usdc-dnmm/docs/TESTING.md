# Testing Strategy

## Tooling
- Run all tests via the root wrapper: `terragon-forge.sh test` (ensures `--root hype-usdc-dnmm`).
- Fuzz tests require Foundry ≥ 1.0.0 with `forge-std` installed.

## Suites
| Path | Coverage |
|------|----------|
| `test/unit/FeePolicy.t.sol` | Fee surface math, caps, decay behaviour. |
| `test/unit/Inventory.t.sol` | Partial fill solver, deviation calculations. |
| `test/unit/DnmPool.t.sol` | Swap happy path, fallback usage, divergence revert. |
| `test/integration/DnmPoolIntegration.t.sol` | Recenter gating, oracle fallback scenarios. |
| `test/integration/FeeDynamics.t.sol` | Fee surface sweeps with CSV emission for base/volatility/inventory components. |
| `test/perf/GasSnapshots.t.sol` | Deterministic gas profiling for HC/EMA/Pyth quotes, swap legs, and RFQ settlement (writes `metrics/gas_snapshots.csv`, `gas-snapshots.txt`). |
| `test/perf/LoadBurst.t.sol` | Burst/load harness producing failure-rate metrics and fee decay series under stress (`metrics/load_*`). |
| `test/unit/TupleSweep.t.sol` | Decimal matrix (Matrix G) sweeps covering getter destructuring and floor drift assertions with CSV outputs. |
| `test/fuzz/DnmPoolFuzz.t.sol` | Randomised amount/reserve checks to enforce floor invariants. |

## Adding Tests
1. Place unit tests under `test/unit/`, integration scenarios under `test/integration/`, fuzz/property tests under `test/fuzz/`.
2. Use mocks in `contracts/mocks/` or extend them for new oracle/token behaviours.
3. When introducing new parameters, include regression tests to assert bounds/regression alerts.

## CI Guidance
- For PRs run the smoke invariant sweep: `FOUNDRY_INVARIANT_RUNS=2000 forge test --profile ci --match-path test/invariants/Invariant_NoRunDry.t.sol` (depth 64, fail-on-revert disabled).
- Schedule the adaptive long sweep via `script/run_invariants.sh` (samples runtime, shards the 20k run, enforces idle/output budgets). Adjust `TARGET_RUNS`, `SHARDS`, and `BUDGET_SECS` via env vars in CI.
- Add staged jobs for `terragon-forge.sh test --match-path test/perf` to refresh gas/load CSVs with thresholds `<1%` partial fills and `≤10%` gas regression using emitted artefacts.
- Persist `metrics/` and `gas-snapshots.txt` as build artefacts and diff against baseline in CI to highlight drift.
- Surface `forge fmt`/`forge test` commands in future CI configuration, disallowing merges when metrics fail thresholds.

Refer to `docs/OBSERVABILITY.md` for runtime metrics complementing the test suite.
