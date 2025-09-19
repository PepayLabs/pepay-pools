# D6 – Rebalancing: v1 vs v2

## Deliverable Elements
- Finite-state description for both designs
- Sequence diagrams (link to `diagrams/rebalance_sequence_v1_v2.mmd`)
- Trigger conditions (`|p/p* - 1| ≥ θ` or equivalent), actions, cooldowns, guardrails
- Observable state fields updated during a rebalance
- Empirical evidence comparing trigger frequency and PnL impacts

## Suggested Structure
1. **v1 Continuous Drift Model** – Virtual reserve evolution, inventory bias behavior.
2. **v2 Threshold Model** – State machine, keeper responsibilities, on-chain markers.
3. **Comparative Analysis** – Metrics from backtests: PnL, fees, inventory variance.
4. **EVM Implications** – Keeper cadence, gas budget, risk of delayed triggers.

Populate with data tables sourced from `data/processed/backtest_results.csv` once simulations are complete.
