# D4 – Algorithms Specification

## Coverage Targets
- Oracle anchoring logic
- Concentration / virtual liquidity adjustments (`K' = c · K_base`)
- Inventory-aware modulation (`K_adjust` as function of imbalance, exponent `z`)
- Slippage computation and rounding rules
- v2 threshold rebalance finite-state machine
- Fee assessment and distribution order
- Guardrails (freshness, confidence, pausing)

## Documentation Structure
1. **Notation & Definitions** – Symbols, units, and assumptions.
2. **Swap Quoting Flow** – Pseudocode linking oracle mid price to slippage curve and fee deduction.
3. **Inventory Adjustment Model** – Equations, calibration approach, empirical validation.
4. **Rebalance Mechanics** – Trigger conditions, cooldowns, state updates, keeper implications.
5. **Edge Cases & Failure Modes** – Handling stale oracles, insufficient liquidity, authority gating.

Embed derivations sourced from logs, state diffs, and backtest regressions. Provide cross-links to empirical validation in D9.
