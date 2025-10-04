# Shadow Bot Runtime Modes

This document explains how the shadow bot operates in each supported mode, what surfaces are enabled, and the operational caveats.

## Mode Overview

| Mode | Description | Primary Use | Dependencies |
| --- | --- | --- | --- |
| `mock` *(default)* | All data is generated locally via the scenario engine and simulators. | CI, local development, regression tests. | None – no chain required. |
| `fork` | Connects to a Hardhat/Foundry fork and reads on-chain state without mutating it. | Pre-production validation with real history. | Fork node (`RPC_URL`), optional fork deploy JSON, address book. |
| `live` | Observes production HyperEVM deployment using read-only RPC calls. | Production monitoring, oncall dashboards. | HyperEVM RPC endpoint, real pool/oracle addresses, API rate limits. |

### Switching Modes

Set `MODE` in `.dnmmenv` (or via environment variable) and provide the required addresses.

```
MODE=live
RPC_URL=https://mainnet.hyperliquid.xyz/rpc
POOL_ADDR=0x...
HYPE_ADDR=0x...
USDC_ADDR=0x...
```

The loader (`src/config.ts`) discovers optional metadata from `address-book.json` and fork deploy snapshots where present.

## Scenario Engine (Mock Mode)

Mock runs rely on `src/mock/scenarios.ts`, which defines deterministic parameter sets (spread, confidence, divergence, AOMQ flags). Each scenario is keyed (e.g. `CALM`, `DELTA_SOFT`, `NEAR_FLOOR`). The engine feeds both the mock oracle and mock pool clients so that tests see coherent state.

## Fork Mode Details

- Provide `FORK_DEPLOY_JSON` that points to the output of the deployment script (pool, token, oracle addresses).
- `config.ts` merges fork overrides with `.dnmmenv` values; CLI flags can override both.
- Fork mode never mutates state; all interactions are read-only.

## Live Mode Details

- Expects production addresses in `.dnmmenv`.
- Retry/backoff settings (`SAMPLING_TIMEOUT_MS`, `SAMPLING_RETRY_ATTEMPTS`, `SAMPLING_RETRY_BACKOFF_MS`) govern how the bot handles RPC hiccups.
- Prometheus metrics reflect the live chain information (same `dnmm_*` namespace) so dashboards remain historical.

---

Last updated: 2025-10-04.
