# D9 – Empirical Findings

## Required Metrics (per scope pool)
- 24h / 7d / 30d volume and TVL snapshots
- Fees per day and turnover (vol/TVL)
- Oracle age distribution at swap execution
- Inventory ratio time series (value_x vs value_y)
- Swap size vs realized slippage curves

## Data Artifacts
- `data/processed/tx_samples.csv`
- `data/processed/pool_state_timeseries.csv`
- `data/processed/slippage_curve.csv`
- `data/processed/fees_timeseries.csv`

## Analysis Plan
1. Build reproducible aggregation notebooks / scripts referencing processed datasets.
2. Segment metrics by volatility regimes to mitigate sampling bias.
3. Compare v1 vs v2 behavior where historical data allows.
4. Quantify simulator accuracy relative to on-chain outputs (≤2 bps median error, 95p ≤10 bps).

Document methodology, caveats, and interpretation of profitability proxies.
