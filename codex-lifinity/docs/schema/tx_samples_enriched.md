# `tx_samples_enriched.csv` Schema

This file is produced by `scripts/swap_enricher.py` and is intended as the staging table for swap-level analyses.

| Column | Type | Description |
| --- | --- | --- |
| `tx_id` | string | Solana transaction signature. |
| `slot` | integer | Slot number associated with the transaction. |
| `block_time` | integer | Unix timestamp (seconds) when available; blank otherwise. |
| `is_inner` | 0/1 integer | Indicates whether the instruction came from an inner invocation. |
| `discriminator` | string | 8-byte discriminator (hex) for the Lifinity instruction. |
| `instruction_name` | string | Human-readable label from `scripts/discriminators.yaml`; defaults to `unknown`. |
| `account_count` | integer | Number of account metas referenced by the instruction. |
| `accounts` | string | Comma-separated list of account public keys. |
| `account_labels` | string | Optional comma-separated labels pulled from the discriminator map. |
| `notes` | string | Free-form notes / TODOs describing decoding status. |

## Next Enhancements
- Join decoded instruction data payloads (amounts, fees) once schema is known.
- Attach pool identifiers by matching vault or config accounts.
- Add oracle freshness, reserve deltas, and output amounts from state diff tooling.
