# D8 – Security Model

## Coverage
- Upgrade / pause / parameter authorities (signers, PDAs, governance links)
- PDA seed derivations and signer graph
- Rent and ownership expectations for critical accounts
- Mitigations for stale oracles, front-running, and parameter misuse
- Assumptions and potential failure modes relevant to EVM porting

## Investigation Steps
- Inspect program data authority and upgrade keys (`solana program show` output)
- Map admin instructions from transaction samples
- Document PDA derivations unearthed via disassembly or SDK cues
- Catalog runtime checks that gate swaps (freshness, signer presence, etc.)

Summarize implications for EVM deployment, including need for privileged roles, timelocks, or circuit breakers.
