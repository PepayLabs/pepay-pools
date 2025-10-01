# Change Log

## 2025-10-01
- feat(pool): add AOMQ micro-quote pipeline behind `enableAOMQ`, including min-notional clamps, soft-divergence triggers, and clamp telemetry.
- feat(pool): introduce preview snapshot + fee APIs (`refreshPreviewSnapshot`, `previewFees`, `previewLadder`, `previewFeesFresh`) sharing the on-chain fee pipeline without mutating state.
- chore(config): add preview configuration knobs (`previewMaxAgeSec`, `snapshotCooldownSec`, `revertOnStalePreview`, `enablePreviewFresh`).
- test: add `PreviewFees_Parity` unit coverage and `Scenario_AOMQ`/`Scenario_Preview_AOMQ` integration flows plus gas benchmarks for previews.
- docs/monitoring: document snapshot lifecycle, router guidance, and wire new Prometheus metrics/alerts for preview staleness.
