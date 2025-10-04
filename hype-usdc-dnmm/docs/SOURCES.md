---
title: "External References"
version: "8e6f14e"
last_updated: "2025-10-04"
---

# External References

| Topic | Reference | Notes |
|-------|-----------|-------|
| HyperEVM HyperCore precompiles | https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore | Official precompile addresses + `L1Read.sol` selectors (retrieved 2025-10-03). |
| Hyperliquid Oracle semantics | `reverse-engineer-lifinity/LIFINITY_V2_EXPLAINED.md` | Baseline mapping between Solana bytecode and DNMM behaviours used for Solidity port. |
| Lifinity pool parameters | `lifinity-contract/lifinity_pools_oracle_config.json` | Source of SOL/USDC oracle caps and freshness settings. |
| Dynamic fee heuristics | `lifinity-contract/CONFIGURATION_VALUES.md` | Basis for α/β multipliers and decay semantics. |
| Pyth EVM integration | https://docs.pyth.network/documentation/pythnet-price-feeds/evm | Defines price ID usage and confidence handling. |
| Core-4 roadmap & LVR spec | `docs/improvements/elite-core-4-to-do.json` | Source of volatility fee, preview freshness, and router allowlist requirements (pulled 2025-10-04). |
| Wad-based LVR derivation reference | Internal analysis – `docs/ALGORITHMS.md` | Documents σ√Δt WAD pipeline that matches on-chain implementation. |
