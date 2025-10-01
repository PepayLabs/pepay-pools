# Change Log

## 2025-10-02
- feat(pool): wire F09 aggregator rebates (`setAggregatorDiscount`, pipeline discount before floor) with events/tests and enforce 3 bps cap.
- feat(pool): harden governance with timelock queue/execute/cancel, `TimelockDelayUpdated`, and `setPauser` helper (F11).
- feat(observer): add `DnmPauseHandler` autopause bridge + integration test, extend runbook for wiring (F12).
- fix(pool): surface `Errors.MidUnset` for swap/preview fail-closed paths and keep `previewFeesFresh` pure.
- test: add `Rebates_FloorPreserve`, `DnmPool_GovernanceTimelock`, `ReadOracle_MidUnset_Coverage`, `Preview_ViewPurity`, and `OracleWatcher_PauseHandler` coverage.
- docs: add `ROUTER_INTEGRATION.md` for volume tiers/off-path routing and update `CONFIG.md`, `FEES_AND_INVENTORY.md`, `OBSERVABILITY.md`, `RUNBOOK.md`, and `CHANGELOG.md` for rebates, timelock operations, autopause, and preview freshness.

## 2025-10-01
- feat(pool): add AOMQ micro-quote pipeline behind `enableAOMQ`, including min-notional clamps, soft-divergence triggers, and clamp telemetry.
- feat(pool): introduce preview snapshot + fee APIs (`refreshPreviewSnapshot`, `previewFees`, `previewLadder`, `previewFeesFresh`) sharing the on-chain fee pipeline without mutating state.
- chore(config): add preview configuration knobs (`previewMaxAgeSec`, `snapshotCooldownSec`, `revertOnStalePreview`, `enablePreviewFresh`).
- test: add `PreviewFees_Parity` unit coverage and `Scenario_AOMQ`/`Scenario_Preview_AOMQ` integration flows plus gas benchmarks for previews.
- docs/monitoring: document snapshot lifecycle, router guidance, and wire new Prometheus metrics/alerts for preview staleness.
