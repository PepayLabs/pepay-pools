# DNMM L3 Verification Checklist (v1.1)

## F01 – Auto / Manual Recenter
- Auto pipeline only runs on state-changing swaps (`contracts/DnmPool.sol:820-859`, `contracts/DnmPool.sol:1471-1499`).
- Manual path enforces threshold + cooldown (`contracts/DnmPool.sol:758-783`).
- Events emitted (`TargetBaseXstarUpdated`, `ManualRebalanceExecuted`) covered by tests (`test/unit/DnmPool_Rebalance.t.sol`).

## F02 – HC Scale Normalisation
- Constructor scales base/quote decimals via `_pow10` (`contracts/DnmPool.sol:333-358`).
- Oracle adapters convert HyperCore spot to WAD (`contracts/oracle/OracleAdapterHC.sol`).
- Fork parity test confirms API equivalence (`test/integration/ForkParity.t.sol`).

## F03 – Soft Divergence Haircut
- Preview + settle share `_readOracleView`/`_processSoftDivergence` (`contracts/DnmPool.sol:1886-1955`, `contracts/DnmPool.sol:2125-2188`).
- Events `DivergenceHaircut`/`DivergenceRejected` emitted with hysteresis (`contracts/DnmPool.sol:2023-2053`).
- Covered by `test/unit/SoftDivergenceTest.t.sol`.

## F04 – Size-Aware Fee
- Linear/quadratic size fees computed with cap (`contracts/DnmPool.sol:1368-1387`).
- Pipeline application gated by flag + S0 (`contracts/DnmPool.sol:1547-1618`).
- Tests: `test/unit/SizeFeeCurveTest.t.sol`.

## F05 – BBO-Aware Floor
- Floor = max(alpha%·spread, betaFloor) (`contracts/DnmPool.sol:1389-1403`).
- Applied after rebates and before final clamp (`contracts/DnmPool.sol:1606-1618`).
- Tests: `test/unit/BboFloorTest.t.sol`.

## F06 – Inventory Tilt Upgrade
- Instantaneous x* math with spread/conf weighting (`contracts/DnmPool.sol:1405-1468`).
- Sign flips by trade direction; capped by config.
- Tests: `test/unit/InventoryTiltTest.t.sol`.

## F07 – AOMQ
- Decision pipeline returns clamp metadata (`contracts/DnmPool.sol:1547-1620`).
- Activation state transitions w/ cooldown (`contracts/DnmPool.sol:1620-1685`).
- Integration: `test/integration/Scenario_AOMQ.t.sol`.

## F08 – Size Ladder View
- `previewFees`/`previewFeesFresh` share `_applyFeePipeline` without storage writes (`contracts/DnmPool.sol:917-1034`, `contracts/DnmPool.sol:1886-1955`).
- View purity enforced by test (`test/unit/Preview_ViewPurity.t.sol`).

## F09 – Rebates Allowlist
- Governance setter + cap + event (`contracts/DnmPool.sol:617-623`).
- Pipeline applies discount pre-floor (`contracts/DnmPool.sol:1606-1618`).
- Tests ensure floor preserved & flag gating (`test/unit/Rebates_FloorPreserve.t.sol`).
- Docs specify order (`docs/FEES_AND_INVENTORY.md:34-45`, `docs/CONFIG.md:18-35`).

## F10 – Volume Tiers Off-Path
- Router process, size buckets, anti-gaming documented (`docs/ROUTER_INTEGRATION.md`).
- Shadow-bot metrics export ladder/size bucket observability (`shadow-bot/shadow-bot.ts:700-1055`).
- Dashboard JSON for monitoring (`shadow-bot/dashboards/dnmm_shadow_metrics.json`).

## F11 – Param Guards & Timelock
- Queue/execute/cancel & delay bounds (`contracts/DnmPool.sol:567-724`).
- Errors for misuse (`contracts/lib/Errors.sol:32-36`).
- Tests: `test/unit/DnmPool_GovernanceTimelock.t.sol`.
- Runbook procedure (`RUNBOOK.md:45-70`).

## F12 – Autopause Watcher
- Pause handler mediates watcher→pool w/ cooldown (`contracts/observer/DnmPauseHandler.sol`).
- Oracle watcher emits `AutoPauseRequested` + handler integration (`contracts/observer/OracleWatcher.sol:200-244`).
- Integration test (`test/integration/OracleWatcher_PauseHandler.t.sol`).
- Runbook wiring steps (`RUNBOOK.md:48-70`).

## Observability & Metrics
- Prometheus series per spec (`shadow-bot/shadow-bot.ts:700-1055`).
- Grafana dashboard covering required panels (`shadow-bot/dashboards/dnmm_shadow_metrics.json`).
- Docs updated (`docs/OBSERVABILITY.md:7-37`).

## Gas & Performance
- Latest snapshot post-changes (`gas-snapshots.txt`, `metrics/gas_snapshots.csv`).
- Perf test command recorded (`test/perf/GasSnapshots.t.sol`).
