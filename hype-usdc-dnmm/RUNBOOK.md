# Deployment Runbook

## Prerequisites
- Governance multisig and pauser EOAs funded with native HYPE for gas.
- Verified HyperCore asset/market identifiers and Pyth price IDs populated in `config/oracle.ids.json`.
- Tokens deployed on HyperEVM with initial protocol-owned liquidity available.
- Foundry installed locally (`terragon-forge.sh test`).

## 1. Parameter Review
1. Validate `config/parameters_default.json` against latest risk sign-off.
2. Confirm token addresses/decimals in `config/tokens.hyper.json`.
3. Update divergence threshold if governance policy changes.

## 2. Contract Deployment
1. `terragon-forge.sh script script/Deploy.s.sol --broadcast --rpc-url <RPC>`
2. Record deployed addresses in the release sheet.
3. Assign governance/pauser roles via constructor parameters or `updateParams`.

## 3. Seeding Liquidity
1. Transfer HYPE and USDC into the pool contract proportionally to desired inventory.
2. Execute `sync()` to align internal reserves.
3. Call `setTargetBaseXstar` to align with initial deposit split.

## 4. Smoke Tests
- Run `terragon-forge.sh test --match-test testSwapBaseForQuoteHappyPath`.
- Submit manual swaps with small size via a fork RPC.
- Verify events through explorer or local indexer.

## 5. RFQ Enablement (Optional)
1. Deploy `QuoteRFQ` with maker key.
2. Fund taker allowances for HYPE/USDC.
3. Monitor `QuoteFilled` for partial fills and expiry behaviour.

## 6. Observability Bring-Up
- Connect indexer to `SwapExecuted`, `QuoteServed`, `ParamsUpdated`, `Paused`, `Unpaused`.
- Publish Grafana dashboard using metrics defined in `docs/OBSERVABILITY.md`.

## 7. Incident Response
- Use `pause()` to halt swaps on oracle deviation or vault issues.
- Investigate telemetry, adjust parameters through `updateParams`.
- Unpause once post-mortem complete and governance approves.

## Appendices
- See `docs/ORACLE.md` for HyperCore/Pyth wiring.
- See `SECURITY.md` for threat model and mitigations.
