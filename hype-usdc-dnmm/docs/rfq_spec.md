# RFQ Specification

## Message Schema
```text
Quote(
  taker: address,
  amountIn: uint256,
  minAmountOut: uint256,
  isBaseIn: bool,
  expiry: uint256,
  salt: uint256,
  pool: address,
  chainId: uint256
)
```
- EIP-191 wrapped before signing (`\x19Ethereum Signed Message\n32`).
- `salt` must be unique per quote; contract enforces single use.

## Settlement Flow
1. Taker submits `(signature, params, oracleData)` to `QuoteRFQ.verifyAndSwap`.
2. Contract validates signer, TTL, and consumes salt.
3. Tokens pulled from taker, forwarded to `DnmPool.swapExactIn` (Spot mode).
4. Unused input balances refunded; output transferred to taker.
5. `QuoteFilled` event emitted with consumed input/output and salt.

## Risk Controls
- Maker key rotation via `setMakerKey` (owner-only).
- Pausing handled upstream at pool level; RFQ call reverts if pool paused.
- Oracle data reused from pool (e.g. includes HyperCore payload, Pyth update bundle).

Refer to `docs/OBSERVABILITY.md` for telemetry fields captured per RFQ fill.
