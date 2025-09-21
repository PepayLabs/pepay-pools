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
| `test/fuzz/DnmPoolFuzz.t.sol` | Randomised amount/reserve checks to enforce floor invariants. |

## Adding Tests
1. Place unit tests under `test/unit/`, integration scenarios under `test/integration/`, fuzz/property tests under `test/fuzz/`.
2. Use mocks in `contracts/mocks/` or extend them for new oracle/token behaviours.
3. When introducing new parameters, include regression tests to assert bounds/regression alerts.

## CI Guidance
- Capture gas snapshots with `terragon-forge.sh test --gas-report` once CI integrates.
- Fail builds on regressions >10% by wiring Foundry's gas snapshot diff into pipeline.
- Surface `forge fmt`/`forge test` commands in future CI configuration.

Refer to `docs/OBSERVABILITY.md` for runtime metrics complementing the test suite.
