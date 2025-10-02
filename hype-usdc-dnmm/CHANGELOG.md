# Change Log

## 2025-10-03
- fix(pool): enforce HyperCore vs Pyth divergence guard for spot quotes using lightweight peek reads, reintroducing `OracleDiverged` fail-closed semantics and aligning perf `DosEconomics` expectations.
- perf(pool): load fee-state words via a single sload and coalesce settle writes, trimming quote/preview reads without touching feature-flag defaults.
- perf(pool): cache feature flags as a single word, tighten AOMQ/fee toggles, and lazily read Pyth to shave quote/swap gas while keeping preview paths view-only.
- fix(rfq): mark inline assembly blocks memory-safe to restore 0.8.24 builds, extend tests for domain caching and ERC1271 fast-path parity.
- test: add gating scenarios ensuring Pyth adapters are skipped when HyperCore is fresh, preview freshness stays pure, and debug emission obeys flags.
- docs: document new oracle gating metrics/alerts in `OBSERVABILITY.md` and note flag bitmask optimisation.

## 2025-10-02
- fix(pool): allow `previewConfig.maxAgeSec` to remain zero (disable staleness guards) while guarding `revertOnStalePreview` checks, update deploy script/test defaults, and standardize zero-mid fallbacks on `Errors.MidUnset`.
- test: recalibrated `Scenario_AOMQ`, `Scenario_Preview_AOMQ`, and `ForkParity` to assert events/flags instead of revert strings, tuned AOMQ knobs (lower min-notional, wider floor epsilon), and refreshed near-floor preview invariants.
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
