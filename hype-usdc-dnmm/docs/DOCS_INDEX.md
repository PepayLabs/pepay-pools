---
title: "Docs Index"
version: "8e6f14e"
last_updated: "2025-10-03"
---

# Docs Index

## Table of Contents
- [Overview](#overview)
- [What to Read First](#what-to-read-first)
- [Document Map](#document-map)
- [Versioning](#versioning)

## Overview
Central index for DNMM documentation. All docs live under `docs/` unless noted.

## What to Read First
Audience | Sequence
--- | ---
Protocol Engineers | `ARCHITECTURE.md` → `ALGORITHMS.md` → `FEES_AND_INVENTORY.md`
SRE / On-call | `RUNBOOK.md` → `OBSERVABILITY.md` → `OPERATIONS.md`
QA & Tooling | `TESTING.md` → `CONFIG.md` → `GOVERNANCE_AND_TIMELOCK.md`
Integrators | `ROUTER_INTEGRATION.md` → `RFQ.md` → `INVENTORY_FLOOR.md`

## Document Map
Category | Document | Description
--- | --- | ---
Architecture | `ARCHITECTURE.md` | System overview, data flow, code links.
Algorithms | `ALGORITHMS.md` | Formal definitions & complexity notes.
Fees & Inventory | `FEES_AND_INVENTORY.md` | Pipeline math and worked examples.
Rebalancing | `REBALANCING_IMPLEMENTATION.md` | Auto/manual recenter internals.
Oracle | `ORACLE.md` | Adapter behavior, errors, fallback ladder.
Divergence | `DIVERGENCE_POLICY.md` | Accept/soft/hard thresholds, hysteresis.
Inventory Floors | `INVENTORY_FLOOR.md` | Floor types, partial fills, AOMQ interplay.
Router Integration | `ROUTER_INTEGRATION.md` | MinOut, TTL/slippage, rebates.
RFQ | `RFQ.md` | EIP-712 flow, preview determinism.
Observability | `OBSERVABILITY.md` | Metric glossary, dashboards, alert rules.
Observers | `ARCHITECTURE.md#observer--autopause-layer`, `docs/OPERATIONS.md` | Autopause watcher + handler overview, runbook tie-in.
Metrics Glossary | `METRICS_GLOSSARY.md` | Contract/bot metric details, KPIs.
Operations | `OPERATIONS.md` | Deployment checklist, feature toggles, runbooks.
Governance | `GOVERNANCE_AND_TIMELOCK.md` | Timelock process, guard rails.
Configuration | `CONFIG.md` | Schema, zero-default posture, safety checks.
Testing | `TESTING.md` | Test matrix, commands, preview parity notes.
Gas | `GAS_OPTIMIZATION_GUIDE.md` | Baselines and optimization tactics.
Docs Index | `DOCS_INDEX.md` | This file.

## Versioning
- Current git commit: `8e6f14e` (2025-10-03).
- Changelog: see `CHANGELOG.md` (`Docs` section) for updates tied to this index.
- When docs change, update `version` and `last_updated` front matter and append entry to `CHANGELOG.md`.
