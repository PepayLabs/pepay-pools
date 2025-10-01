# DNMM L3 Feature Matrix

| Feature | Status | Key References |
| --- | --- | --- |
| F01 – Auto/Manual Recenter | ✅ Complete | `contracts/DnmPool.sol:747-783` (manual path), `contracts/DnmPool.sol:1471-1502` (auto pipeline), `test/unit/DnmPool_Rebalance.t.sol` |
| F02 – HC Scale Normalisation | ✅ Complete | `contracts/DnmPool.sol:333-358`, `contracts/oracle/OracleAdapterHC.sol`, `test/integration/ForkParity.t.sol` |
| F03 – Soft Divergence Haircut | ✅ Complete | `contracts/DnmPool.sol:1862-1885`, `contracts/DnmPool.sol:2125-2188`, `test/unit/SoftDivergenceTest.t.sol` |
| F04 – Size-Aware Fee | ✅ Complete | `contracts/DnmPool.sol:1547-1585`, `contracts/DnmPool.sol:1368-1387`, `test/unit/SizeFeeCurveTest.t.sol` |
| F05 – BBO-Aware Floor | ✅ Complete | `contracts/DnmPool.sol:1389-1403`, `test/unit/BboFloorTest.t.sol` |
| F06 – Inventory Tilt Upgrade | ✅ Complete | `contracts/DnmPool.sol:1405-1468`, `test/unit/InventoryTiltTest.t.sol` |
| F07 – AOMQ | ✅ Complete | `contracts/DnmPool.sol:1547-1585`, `contracts/DnmPool.sol:1620-1685`, `test/integration/Scenario_AOMQ.t.sol` |
| F08 – Size Ladder View | ✅ Complete | `contracts/DnmPool.sol:917-968`, `contracts/DnmPool.sol:1886-1955`, `test/integration/PreviewParity.t.sol` |
| F09 – Rebates Allowlist | ✅ Complete | `contracts/DnmPool.sol:617-623`, `contracts/DnmPool.sol:1606-1618`, `test/unit/Rebates_FloorPreserve.t.sol`, `docs/FEES_AND_INVENTORY.md:34-45` |
| F10 – Volume Tiers Off-Path | ✅ Complete | `docs/ROUTER_INTEGRATION.md`, `docs/OBSERVABILITY.md:7-37`, `shadow-bot/dashboards/dnmm_shadow_metrics.json` |
| F11 – Param Guards & Timelock | ✅ Complete | `contracts/DnmPool.sol:567-724`, `contracts/lib/Errors.sol:32-36`, `test/unit/DnmPool_GovernanceTimelock.t.sol`, `RUNBOOK.md:45-70` |
| F12 – Autopause Watcher | ✅ Complete | `contracts/observer/DnmPauseHandler.sol`, `contracts/observer/OracleWatcher.sol:200-244`, `test/integration/OracleWatcher_PauseHandler.t.sol`, `RUNBOOK.md:45-70` |

_Status legend_: ✅ complete, ⚠︎ partial, ⭕ missing.
