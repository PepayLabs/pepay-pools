# D2 – Instruction Catalog

## Deliverable Checklist
- [ ] 8-byte discriminator recovered for every public instruction
- [ ] Account metas documented (order, signer, writable)
- [ ] Data schema annotated (field names, types, endianness)
- [ ] Pre/post-state invariants + canonical error codes captured

## Table Template
| Discriminator | Instruction | Account Metas | Data Schema | Notes |
| --- | --- | --- | --- | --- |

## Worklog
- TODO: Ingest transaction samples into `data/raw/tx_samples.csv`
- TODO: Parse discriminators via `scripts/tx_sampler.py`
- TODO: Cross-reference with SDK or disassembly for schema hints

Document any unknown fields explicitly with rationale and bounds.
