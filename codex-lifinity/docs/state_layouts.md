# D3 – State Layouts

## Objective
Recover byte-accurate layouts for Lifinity pool PDAs, configuration records, fee accumulators, and admin authority state.

## Requirements
- [ ] Field offsets & sizes annotated
- [ ] Type interpretations justified (u64 LE, Pubkey, bool, etc.)
- [ ] Versioning / discriminators recorded
- [ ] Unknown bytes labeled with hypotheses or TODOs

## Suggested Format
```
Offset | Size | Type | Field | Notes
```

## Pending Actions
- Collect paired `getAccountInfo` dumps pre/post swap into `data/raw/pool_states/`.
- Use `scripts/state_diff.py` to diff snapshots and infer mutating fields.
- Compare against SDK structs (if available) and disassembly writes for confirmation.

Highlight cross-field relationships (e.g., fee counters referencing vault balances) and link to algorithm spec once derived.
