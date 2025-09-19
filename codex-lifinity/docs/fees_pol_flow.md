# D7 – Fees & Protocol-Owned Liquidity Flow

## Questions to Answer
- How swap fees are computed, stored, and distributed between LPs and protocol
- Location of fee counters (state fields vs vault balances)
- Withdrawal instructions, authorities, and POL custody accounts
- Historical fee accrual metrics (per token, per pool) and turnover calculations

## Data & Evidence
- Track fee-related fields in state diffs (`data/raw/pool_states/`)
- Capture fee withdrawal transactions and decode account metas
- Maintain `data/processed/fees_timeseries.csv` with 24h/7d/30d aggregates

## Documentation Template
1. **Fee Formula & Order of Operations**
2. **Accounting Model** – Where fees reside pre/post collection
3. **Authorities & Access Control** – Who can withdraw, pause, or redirect fees
4. **Protocol-Owned Liquidity** – Locations, size estimates, observed usage
5. **Empirical KPIs** – Fees/TVL, turnover, comparison vs alternative AMMs
