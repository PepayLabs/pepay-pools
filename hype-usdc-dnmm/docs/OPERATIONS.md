---
title: "Operations"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Operations

## Table of Contents
- [Deployment Checklist](#deployment-checklist)
- [Feature Flag Enablement](#feature-flag-enablement)
- [Runbook Procedures](#runbook-procedures)
- [Autopause Integration](#autopause-integration)
- [Canary & A/B Rollouts](#canary--ab-rollouts)
- [References](#references)

## Deployment Checklist
1. **Contracts:**
   - Deploy `DnmPool` with zero-default feature flags (all disabled) and baseline configs from `config/parameters_default.json`.
   - Deploy `QuoteRFQ` pointing at the pool if RFQ trading required.
2. **Adapters:**
   - Configure HyperCore IDs in `config/oracle.ids.json` before constructor call (`contracts/oracle/OracleAdapterHC.sol`).
   - Set Pyth price IDs / price feeds; confirm `maxAgeSec` matches network.
3. **Guardians:**
   - Assign `governance`, `pauser`, `treasury` addresses (`contracts/interfaces/IDnmPool.sol:63`).
   - Stage timelock delay via governance queue if non-zero.
4. **Shadow Bot:**
   - Populate `.env` with RPCs, Prometheus port, and address book entries (`shadow-bot/README.md`).
   - Launch in `MOCK` mode for smoke tests, then `LIVE` with production RPCs.

## Feature Flag Enablement
Flag | Default | Effect | Activation Steps
--- | --- | --- | ---
`enableAutoRecenter` | `false` | Allows `_checkAndRebalanceAuto` to run during swaps. | Queue `IDnmPool.ParamKind.FeatureFlags` update; wait timelock; execute; monitor `dnmm_recenter_commits_total`.
`enableSizeFee` | `false` | Adds size-aware fee curve. | Update fee config + feature flags; confirm new gas vs `SizeFeeCurveTest`.
`enableBboFloor` | `false` | Enables `_computeBboFloor` enforcement. | Update maker config; monitor AOMQ clamps.
`enableInvTilt` | `false` | Turns on inventory tilt adjustments. | Ensure `inventory.*` weights configured before enabling.
`enableAOMQ` | `false` | Activates AOMQ clamps for degraded states. | Tune `aomq.*` parameters; watch `dnmm_aomq_clamps_total`.
`enableRebates` | `false` | Allows aggregator discount schedule. | Populate allowlist; ensure `QuoteRFQ` integrates minOut.
`blendOn` | `false` | Enables confidence blend pipeline. | Validate `dnmm_conf_bps` histograms tighten.
`parityCiOn` | `false` | Turns on preview parity CI gating (`test/integration/PreviewParity.t.sol`). | Run CI before mainnet migration.

## Runbook Procedures
- **Pause:** Call `pause()` via guardian or governance when divergence > hard cap or pool mispricing suspected (`contracts/DnmPool.sol:615`). Confirm event `Paused(address)` emitted.
- **Unpause:** After mitigation, call `unpause()`; rerun `Scenario_CalmFlow` to confirm pipeline.
- **Refresh Preview:** `refreshPreviewSnapshot(OracleMode.Relaxed, oracleData)` if `dnmm_snapshot_age_sec` drifts.
- **Manual Recenter:** Invoke `manualRebalance` when reserves drift beyond target and auto flag disabled. Validate `ManualRebalanceExecuted` event.
- **Parameter Updates:** Use governance queue (`queueParamUpdate`) → wait timelock → `executeParamUpdate`; cross-check with `CONFIG.md` schema.

## Autopause Integration
- `OracleWatcher` monitors divergence/age thresholds and emits pause intents (`contracts/observer/OracleWatcher.sol:200`).
- `DnmPauseHandler` consumes watcher alerts, invoking `pause()` on the pool (`contracts/observer/DnmPauseHandler.sol:22`).
- Shadow bot metric `dnmm_precompile_errors_total` > 0 and `dnmm_delta_bps` spikes should trigger the autopause playbook (`RUNBOOK.md`).

## Canary & A/B Rollouts
1. Deploy new configuration to **Canary Pool** with limited maker notional.
2. Enable feature flags incrementally:
   - Phase 1: `blendOn`, `enableBboFloor`.
   - Phase 2: `enableSizeFee`, `enableInvTilt`.
   - Phase 3: `enableAOMQ`, `enableAutoRecenter`.
3. Compare canary metrics vs production using Grafana dashboards; require `dnmm_two_sided_uptime_pct` within ±0.2%.
4. Promote configuration to production via governance queue once canary stable for ≥24h (absolute date tracking in rollout doc).

## References
- Contracts: `contracts/DnmPool.sol`, `contracts/observer/*`, `contracts/quotes/QuoteRFQ.sol`
- Docs: `RUNBOOK.md`, `docs/CONFIG.md`, `docs/DIVERGENCE_POLICY.md`
- Tests: `test/integration/Scenario_DivergenceTripwire.t.sol`, `test/integration/Scenario_CanaryShadow.t.sol`
