# DNMM Level 3 Audit - Navigation Index

**Audit Date**: 2025-10-01
**Repository**: `/home/xnik/pepayPools/hype-usdc-dnmm`

---

## 📚 Quick Start

**New to this audit?** Start here:
1. Read [`DNMM_L3_AUDIT_SUMMARY.md`](./DNMM_L3_AUDIT_SUMMARY.md) (15 min)
2. Review [`DNMM_L3_VERIFICATION_MATRIX.md`](./DNMM_L3_VERIFICATION_MATRIX.md) (10 min)
3. Apply patches from [`DNMM_L3_PATCHES.md`](./DNMM_L3_PATCHES.md) (30 min)

---

## 📋 Audit Deliverables

### 1. Executive Summary
**File**: [`DNMM_L3_AUDIT_SUMMARY.md`](./DNMM_L3_AUDIT_SUMMARY.md) (600 lines)

**Contents**:
- Overall status: 85% production-ready
- Feature implementation status (F01-F12)
- Gas analysis and security checklist
- Test coverage summary
- Deployment roadmap
- Risk assessment and recommendations

**Key Finding**: **Deploy to canary after applying 3 patches (F08, F09, F11)**

---

### 2. Verification Matrix
**File**: [`DNMM_L3_VERIFICATION_MATRIX.md`](./DNMM_L3_VERIFICATION_MATRIX.md) (850 lines)

**Contents**:
- Detailed F01-F12 checklist with line references
- Code quality analysis (state mutation, arithmetic, access control, gas)
- Test coverage breakdown (64 test files)
- Documentation status
- Security threat model
- Acceptance criteria validation

**Use Case**: Reference guide for feature verification and code review

---

### 3. Implementation Patches
**File**: [`DNMM_L3_PATCHES.md`](./DNMM_L3_PATCHES.md) (530 lines)

**Contents**:
- **Patch 1**: F08 - SIZE_LADDER_VIEW (previewFees function)
- **Patch 2**: F09 - REBATES_ALLOWLIST (complete implementation)
- **Patch 3**: F11 - PARAM_GUARDS_TIMELOCK (two-step schedule/commit)
- Unified diffs ready to apply
- Test files for each patch (PreviewFeesTest, RebatesTest, TimelockTest)
- Gas impact estimates

**Use Case**: Apply patches to reach production-ready state

---

### 4. Shadow Bot Metrics System
**Directory**: [`hype-usdc-dnmm/shadow-bot/`](./hype-usdc-dnmm/shadow-bot/)

**Files**:
- `metrics-exporter.ts` (380 lines) - Prometheus metrics collection
- `dashboards/oracle-health.json` - Grafana dashboard (oracle metrics)
- `dashboards/quote-health.json` - Grafana dashboard (quote health)
- `dashboards/inventory-rebalancing.json` - Grafana dashboard (inventory)
- `README.md` - Comprehensive setup and usage guide

**Metrics**: 12 series covering oracle health, quotes, inventory, uptime
**Alerts**: 6 pre-configured alerts for production monitoring

**Use Case**: Real-time telemetry and alerting for production deployment

---

## 🎯 Feature Status Quick Reference

| ID | Feature | Status | Files | Tests |
|----|---------|--------|-------|-------|
| F01 | AUTO_MANUAL_RECENTER | ✅ COMPLETE | DnmPool.sol:176-178, 612, 1239 | DnmPool_Rebalance.t.sol |
| F02 | HC_SCALE_NORMALIZATION | ✅ COMPLETE | OracleAdapterHC.sol:23, 101-134 | OracleAdapterHC.t.sol |
| F03 | SOFT_DIVERGENCE_HAIRCUT | ✅ COMPLETE | DnmPool.sol:68-72, 1463 | SoftDivergenceTest.t.sol |
| F04 | SIZE_AWARE_FEE | ✅ COMPLETE | FeePolicy.sol:36-38, DnmPool.sol:1112 | SizeFeeCurveTest.t.sol |
| F05 | BBO_AWARE_FLOOR | ✅ COMPLETE | DnmPool.sol:78-79, 1157 | BboFloorTest.t.sol |
| F06 | INVENTORY_TILT | ✅ COMPLETE | DnmPool.sol:51-54, 1173 | InventoryTiltTest.t.sol |
| F07 | AOMQ | ✅ COMPLETE | DnmPool.sol:82-86, 950 | Scenario_AOMQ.t.sol |
| F08 | SIZE_LADDER_VIEW | ❌ MISSING → 📋 PATCH | Patch lines 40-150 | PreviewFeesTest.t.sol (provided) |
| F09 | REBATES_ALLOWLIST | ⚠️ PARTIAL → 📋 PATCH | Patch lines 183-299 | RebatesTest.t.sol (provided) |
| F10 | VOLUME_TIERS_OFFPATH | 🟢 BY DESIGN | docs/TIER_STRUCTURE_ANALYSIS.md | N/A (off-chain) |
| F11 | PARAM_GUARDS_TIMELOCK | ⚠️ PARTIAL → 📋 PATCH | Patch lines 349-530 | TimelockTest.t.sol (provided) |
| F12 | AUTOPAUSE_WATCHER | ✅ COMPLETE | contracts/observer/OracleWatcher.sol | OracleWatcher.t.sol |

**Legend**:
- ✅ COMPLETE = Production-ready
- ⚠️ PARTIAL = Needs patch
- ❌ MISSING = Needs patch
- 🟢 BY DESIGN = Intentionally off-chain
- 📋 PATCH = Patch provided in DNMM_L3_PATCHES.md

---

## 🚀 Quick Action Guide

### For Developers

**To apply patches**:
```bash
cd /home/xnik/pepayPools/hype-usdc-dnmm

# Review patches first
cat ../DNMM_L3_PATCHES.md

# Apply patches (adjust paths as needed)
# Option 1: Manual application (recommended for first time)
# Copy/paste diffs from DNMM_L3_PATCHES.md

# Option 2: Automated (if using git-compatible diffs)
# patch -p1 < ../DNMM_L3_PATCHES.md

# Run tests
forge test -vvv

# Update gas snapshots
forge snapshot

# Run slither
slither . --config-file slither.config.json
```

**To run shadow-bot metrics**:
```bash
cd /home/xnik/pepayPools/hype-usdc-dnmm/shadow-bot

# Install dependencies
npm install ethers prom-client express

# Configure environment
cp .env.example .env
# Edit .env with your deployment addresses

# Run exporter
npm run start:metrics

# Verify metrics
curl http://localhost:9090/metrics
```

---

### For Auditors

**Verification checklist**:
- [ ] Review feature implementation status in [`DNMM_L3_VERIFICATION_MATRIX.md`](./DNMM_L3_VERIFICATION_MATRIX.md)
- [ ] Verify each F01-F12 line reference matches code
- [ ] Validate test coverage (64 test files)
- [ ] Check gas snapshots within budget
- [ ] Review security checklist (9/10 passing)
- [ ] Validate config → feature flag mapping

**Code review targets**:
- `contracts/DnmPool.sol` (main pool contract)
- `contracts/lib/FeePolicy.sol` (size-aware fees)
- `contracts/observer/OracleWatcher.sol` (autopause)
- `test/unit/` (23 unit test files)
- `test/integration/` (15 integration scenarios)

---

### For Operators

**Monitoring setup**:
1. Deploy shadow-bot metrics exporter
2. Configure Prometheus scraping (`:9090/metrics`)
3. Import 3 Grafana dashboards
4. Set up alert routing (Slack/Discord/PagerDuty)

**Critical metrics**:
- `dnmm_reject_rate_pct_5m` < 0.5%
- `dnmm_two_sided_uptime_pct` ≥ 99%
- `dnmm_delta_bps` < 75 (hard divergence threshold)
- `dnmm_inventory_dev_bps` < 750 (recenter threshold)

**Runbooks**:
- Oracle health: [`hype-usdc-dnmm/docs/OPERATIONS.md`](./hype-usdc-dnmm/docs/OPERATIONS.md)
- Incident response: [`DNMM_L3_AUDIT_SUMMARY.md`](./DNMM_L3_AUDIT_SUMMARY.md) § Operational Runbook

---

## 📊 Metrics & Dashboards

### Grafana Dashboards

**1. Oracle Health** (`dashboards/oracle-health.json`)
- Oracle divergence (delta BPS)
- Pyth confidence
- HyperCore spread
- Divergence decision breakdown
- Reject rate alert (> 0.5%)
- Precompile error rate alert (> 0.1/5m)

**2. Quote Health** (`dashboards/quote-health.json`)
- Two-sided uptime (target ≥ 99%)
- Ask/Bid fee BPS
- Size bucket distribution
- Fee ladder visualization
- Decision type rate

**3. Inventory & Rebalancing** (`dashboards/inventory-rebalancing.json`)
- Inventory deviation from x*
- Recenter commit events
- Recenter rate per hour
- Restorative trade win rate (target 60-80%)

### Alert Configuration

| Alert | Threshold | Action |
|-------|-----------|--------|
| Soft Divergence | delta > 50 bps (15m avg) | Notify: AOMQ may activate |
| High Reject Rate | > 0.5% over 5m | Investigate oracle health |
| Low Uptime | < 98.5% | Check AOMQ degradation |
| High Inventory Dev | > 750 bps for 30m | Manual recenter needed |
| Precompile Errors | > 0.1/5m | Check HyperCore availability |
| Low Restorative Win | < 60% for 15m | Tilt miscalibration |

---

## 📖 Documentation Map

### Existing Repository Docs

| Doc | Location | Purpose |
|-----|----------|---------|
| ARCHITECTURE | `hype-usdc-dnmm/docs/ARCHITECTURE.md` | System design & data flow |
| OPERATIONS | `hype-usdc-dnmm/docs/OPERATIONS.md` | Deployment & monitoring |
| REBALANCING | `hype-usdc-dnmm/docs/REBALANCING_IMPLEMENTATION.md` | F01 auto-recenter spec |
| DIVERGENCE_POLICY | `hype-usdc-dnmm/docs/DIVERGENCE_POLICY.md` | F03 soft divergence spec |
| CONFIG | `hype-usdc-dnmm/docs/CONFIG.md` | Parameter management |
| RUNBOOK | `hype-usdc-dnmm/docs/RUNBOOK.md` | Deployment procedures |

### Audit-Generated Docs

| Doc | Location | Purpose |
|-----|----------|---------|
| AUDIT SUMMARY | `DNMM_L3_AUDIT_SUMMARY.md` | Executive summary & roadmap |
| VERIFICATION MATRIX | `DNMM_L3_VERIFICATION_MATRIX.md` | Feature verification checklist |
| PATCHES | `DNMM_L3_PATCHES.md` | Implementation patches (F08, F09, F11) |
| SHADOW BOT | `hype-usdc-dnmm/shadow-bot/README.md` | Metrics system guide |
| INDEX (this file) | `DNMM_L3_AUDIT_INDEX.md` | Navigation guide |

---

## 🔧 Troubleshooting

### Common Issues

**Issue**: "Patch doesn't apply cleanly"
- **Solution**: Apply diffs manually by copying code blocks into files

**Issue**: "Tests fail after applying patches"
- **Solution**: Verify you applied all 3 patches (F08, F09, F11). Run `forge test -vvv` to see detailed errors.

**Issue**: "Shadow-bot metrics not appearing"
- **Solution**: Check RPC connectivity, verify pool address, ensure Prometheus is scraping `:9090/metrics`

**Issue**: "Grafana dashboards show no data"
- **Solution**: Verify Prometheus data source configured, check metrics endpoint is accessible, ensure exporter is running

---

## 📞 Support & Next Steps

### Immediate Actions (Today)
1. ✅ Review [`DNMM_L3_AUDIT_SUMMARY.md`](./DNMM_L3_AUDIT_SUMMARY.md)
2. ✅ Review [`DNMM_L3_VERIFICATION_MATRIX.md`](./DNMM_L3_VERIFICATION_MATRIX.md)
3. ✅ Plan patch application timeline

### This Week
4. ✅ Apply patches from [`DNMM_L3_PATCHES.md`](./DNMM_L3_PATCHES.md)
5. ✅ Run full test suite + slither
6. ✅ Update 5 documentation files

### Next 2 Weeks
7. ✅ Deploy canary with shadow-bot metrics
8. ✅ Run 72h A/B test (treatment vs control)
9. ✅ Validate acceptance criteria

### Contact
- **Repository**: `/home/xnik/pepayPools/hype-usdc-dnmm`
- **Issues**: See `docs/OPERATIONS.md` for incident response
- **Maintainers**: TBD (assign in `CLAUDE.md`)

---

**Audit Version**: 1.0.0
**Last Updated**: 2025-10-01
**Tool**: Claude Code (Automated Analysis)
