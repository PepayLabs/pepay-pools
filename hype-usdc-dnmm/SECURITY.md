# Security Overview

## Trust Model
- **Governance**: Multisig controls parameter updates and unpausing.
- **Pauser**: Fast-path account permitted to pause swaps in emergencies.
- **Maker Service**: Optional RFQ signer; compromise limited to signed quotes within TTL.

## Key Controls
- **Reentrancy Guard**: `swapExactIn` and `QuoteRFQ.verifyAndSwap` protected by `nonReentrant`.
- **Access Checks**: `onlyGovernance` and `onlyPauser` modifiers gate sensitive calls.
- **Oracle Validation**: Age, spread, and divergence checks across HyperCore and Pyth.
- **Inventory Floors**: Library-enforced partial fills prevent vault depletion.
- **Fee Caps**: Dynamic fee surface bounded by chain-configured cap.
- **Safe Transfers**: `SafeTransferLib` wraps ERC-20 interactions with return-data checks.

## Suggested Audits
1. Validate fixed-point math under extreme inventory or price inputs.
2. Review HyperCore precompile interface once final selectors are published.
3. Confirm `Inventory` partial solver invariants using fuzz tests (`test/fuzz/DnmPoolInventory.t.sol`).

## Operational Safeguards
- Monitor divergence reverts; spikes may indicate oracle desync.
- Configure alerting for partial fill ratios > 10% of notional.
- Timelock governance parameter changes where feasible.

## Out-of-Scope
- Hedge keeper integration (v2 roadmap).
- External market making strategy risk.
