# D11 – EVM Porting Report

## Objectives
- Provide blueprint for implementing Lifinity mechanics on BNB Smart Chain and Base
- Identify required contracts, keepers, oracle adapters, and integration touchpoints
- Estimate gas costs for swaps, rebalances, and fee collection
- Map Solana parameters (c, z, θ, fees) to EVM equivalents with recommended defaults
- Highlight chain-specific nuances (finality, oracle availability, fee markets)

## Report Structure
1. **Executive Summary** – Portability verdict and key blockers.
2. **Component Decomposition** – PoolCore, OracleAdapter, RebalanceKeeper, FeeRouter, AggregatorAdapter.
3. **Parameter Translation Table** – Derived from algorithm spec and empirics.
4. **Operational Considerations** – Keeper frequency, gas budgeting, failure handling.
5. **Chain Comparisons** – BNB vs Base (latency, liquidity venues, oracle infra, MEV landscape).
6. **Risk & Mitigation Register** – Technical, operational, regulatory.
7. **Implementation Checklist** – Steps to reach feature parity.

Populate with synthesized findings as upstream analyses complete.
