# RFQ Specification

## EIP-712 Domain
- `name`: `DNMM QuoteRFQ`
- `version`: `1`
- `chainId`: runtime `block.chainid`
- `verifyingContract`: `QuoteRFQ` deployment address

Domain separator is cached on deploy and recomputed if `chainId` changes, ensuring signatures bind to the deployed contract instance.

## Message Schema
```text
Quote(
  taker: address,
  amountIn: uint256,
  minAmountOut: uint256,
  isBaseIn: bool,
  expiry: uint256,
  salt: uint256
)
```
- Hash with `keccak256(abi.encode(QUOTE_TYPEHASH, ...))` where `QUOTE_TYPEHASH = keccak256("Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt)")`.
- Typed data digest: `EIP712.hashTypedDataV4(structHash)` = `keccak256("\x19\x01" || domainSeparator || structHash)`.
- `salt` must be unique per quote; contract enforces single use.

## Settlement Flow
1. Taker submits `(signature, params, oracleData)` to `QuoteRFQ.verifyAndSwap`.
2. Contract validates signer via `verifyQuoteSignature(makerKey, params, signature)`, checks TTL, and consumes salt.
3. Tokens pulled from taker, forwarded to `DnmPool.swapExactIn` (Spot mode).
4. Unused input balances refunded; output transferred to taker.
5. `QuoteFilled` event emitted with consumed input/output and salt.

## Signing Guidance
- Maker services should derive the struct hash via `QuoteRFQ.hashQuote(params)` and the signable digest via `QuoteRFQ.hashTypedDataV4(params)` (or mirror the domain/struct hashes above).
- Set `RFQ_SIGNER_PK` / `RFQ_SIGNER_ADDR` in CI or Terragon env vars; unit tests automatically pick up the values and assert key/address alignment.
- Never persist raw private keys in config files. Load via runtime env only. Tests fall back to deterministic dev key `0xA11ce` if env vars are absent.

## Risk Controls
- Maker key rotation via `setMakerKey` (owner-only).
- Pausing handled upstream at pool level; RFQ call reverts if pool paused.
- Oracle data reused from pool (e.g. includes HyperCore payload, Pyth update bundle).

Refer to `docs/OBSERVABILITY.md` for telemetry fields captured per RFQ fill.
