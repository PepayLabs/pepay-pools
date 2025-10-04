# Shadow Bot Runtime Modes

This document explains how the shadow bot operates in each supported mode, what surfaces are enabled, and the operational caveats.

## Mode Overview

| Mode | Description | Primary Use | Dependencies |
| --- | --- | --- | --- |
| `mock` *(default)* | All data is generated locally via the scenario engine and simulators. | CI, local development, regression tests. | None – no chain required. |
| `fork` | Connects to a Hardhat/Foundry fork and reads on-chain state without mutating it. | Pre-production validation with real history. | Fork node (`RPC_URL`), optional fork deploy JSON, address book, HyperCore/Pyth precompile IDs. |
| `live` | Observes production HyperEVM deployment using read-only RPC calls. | Production monitoring, oncall dashboards. | HyperEVM RPC endpoint, real pool/oracle addresses, API rate limits. |

### Switching Modes

Set `MODE` in `.dnmmenv` (or via environment variable) and provide the required addresses. The loader resolves missing values from the address book or fork deploy snapshot.

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

- Provide `FORK_DEPLOY_JSON` pointing to the output of the deployment script (pool/token/oracle/Hype/USDC, hypercore precompiles, keys).
- Optional overrides via env: `POOL_ADDR`, `HYPE_ADDR`, `USDC_ADDR`, `PYTH_ADDR`, `HC_PX_PRECOMPILE`, `HC_BBO_PRECOMPILE`, `HC_PX_KEY`, `HC_BBO_KEY`, `WS_URL`.
- `config.ts` merges (CLI flags) → env vars → fork deploy JSON → address book entries. Missing values throw explicit errors.
- Fork mode never mutates state; all interactions are read-only.
- When `PYTH_MAX_AGE_SEC_STRICT` (via parameters) is exceeded, trades are rejected with `PythStaleStrict` so fork smoke tests surface freshness issues.

## Live Mode Details

- Expects production addresses in `.dnmmenv`.
- Retry/backoff settings (`SAMPLING_TIMEOUT_MS`, `SAMPLING_RETRY_ATTEMPTS`, `SAMPLING_RETRY_BACKOFF_MS`) govern how the bot handles RPC hiccups.
- Prometheus metrics reflect the live chain information (same `dnmm_*` namespace) so dashboards remain historical.

---

Last updated: 2025-10-04.
