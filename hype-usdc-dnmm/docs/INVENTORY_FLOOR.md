# Inventory Floor Guarantees

Inventory floors cap how much inventory the pool is willing to sell on either side of the book. The solver now enforces the following invariants for both base-in and quote-in flows:

## Hard Floor Preservation
- Let `floor = floorAmount(reserves, floorBps)`.
- For every quote, the solver clamps `amountOut <= reserves - floor`.
- Post-trade reserves are guaranteed to satisfy `reserves' >= floor` even under tiny swaps and high fee settings.

## Input Conservation
When a swap would breach a floor, the solver computes the largest fill that still respects the floor and returns the remainder to the taker:

```
requestedAmountIn = appliedAmountIn + leftoverReturned
```

No “dust” is orphaned inside the pool—unused tokens stay with the trader.

## Monotonicity Around the Clamp
- `amountIn` is monotone: increasing it can never reduce the quoted `amountOut`.
- Once the floor is hit the solver returns the maximal fill allowed by the floor; additional size only increases the leftover that is returned.

## Rounding Discipline
- Outputs are rounded in the conservative (downward) direction.
- Inputs required to achieve a clamped fill are rounded up just enough to meet the target, ensuring the floor is never crossed but takers never overpay.

## Test Coverage
Property tests in `test/property/Inventory_FloorMonotonic.t.sol` fuzz reserves, fees, and prices to assert the invariants above. Unit tests cover deterministic scenarios (exact floor hits, near-floor swaps, and quote/bid symmetry).
