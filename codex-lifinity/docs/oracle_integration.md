# D5 – Oracle Integration

## Targets
- Identify oracle programs (Pyth accounts, Switchboard if applicable)
- Freshness thresholds (slots, staleness) and confidence width requirements
- Oracle account meta ordering + permissions per instruction
- Accept / reject decision rules with concrete transaction examples

## Data Collection Plan
1. Capture oracle accounts referenced per swap in `data/processed/oracle_usage.csv`.
2. Record slot differences between swap execution and oracle publish times.
3. Observe error codes or no-op behavior when oracle constraints fail.

## Documentation Outline
- Oracle Account Registry (address, product symbol, owner)
- Freshness & Confidence Checks (equations, thresholds, enforcement point)
- Example Cases (accepted vs rejected with linkable tx IDs)
- Portability Considerations (Chainlink/Pyth wrappers, keeper frequency, latency tolerance)
