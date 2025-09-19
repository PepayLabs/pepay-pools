# D1 – Architecture README

## Objective
Establish a narrative map of Lifinity v2 core components to support portability analysis to EVM chains.

## Current Status
- [ ] Program + account inventory validated
- [ ] Control flow mapped from initialization through swaps, fee accrual, and rebalance
- [ ] Authorities and governance delineated

## Outline
1. **Program Overview** – Summarize `lifinity_v2_core`, ancillary programs, and on-chain dependencies.
2. **Account Topology** – Describe pool PDA, vaults, oracle feeds, fee vaults, POL accounts, admin records.
3. **Lifecycle Flow** – Document sequence from init → oracle read → swap execution → fee updates → optional rebalance.
4. **Invariants & Assumptions** – Capture constraints (e.g., oracle freshness, reserve balances, authority checks).
5. **Portability Notes** – Highlight Solana-specific mechanics that need adaptation on EVM.

Populate sections with recovered evidence (tx logs, disassembly references, SDK snippets). Link to supplementary diagrams once produced.
