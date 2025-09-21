# Lifinity V2 → EVM Porting Implementation Guide

## Implementation Roadmap

### Phase 1: Core Math Library (2 weeks)
- Implement concentrated liquidity calculations
- Port inventory adjustment algorithms
- Create oracle price integration math

### Phase 2: Pool Core Contract (3 weeks)
- Implement swap exact input/output functions
- Add fee collection mechanisms
- Integrate oracle price feeds

### Phase 3: V2 Rebalancing (2 weeks)
- Implement threshold-based rebalancing
- Create keeper infrastructure
- Add automated rebalance triggers

### Phase 4: Testing & Optimization (1 week)
- Gas optimization
- Security testing
- Integration testing

## Smart Contract Architecture

### LifinityPoolCore.sol
- Main AMM logic with oracle-anchored pricing
- Concentrated liquidity management
- Swap execution with inventory adjustment

### OracleAdapter.sol
- Chainlink price feed integration
- Price validation and staleness checks
- Multi-oracle aggregation support

### RebalanceKeeper.sol
- Threshold monitoring
- Automated rebalancing execution
- Cooldown period enforcement

### ConcentratedLiquidityMath.sol
- Concentrated liquidity calculations
- Inventory adjustment formulas
- Fixed-point arithmetic utilities

### PoolFactory.sol
- Pool creation and registration
- Parameter validation
- Access control management

## Parameter Configuration

| Solana Parameter | EVM Equivalent | Scaling | Description |
|------------------|----------------|---------|-------------|
| concentration_factor_c | uint256 (scaled by 1e18) | Various | Liquidity concentration around oracle price |
| inventory_exponent_z | uint256 (basis points) | Various | Asymmetric liquidity adjustment factor |
| rebalance_threshold_theta | uint256 (basis points) | Various | Price deviation trigger for rebalancing |
| oracle_staleness | uint256 (seconds instead of slots) | Various | Maximum acceptable oracle age |

## Gas Optimization Recommendations

1. **Use assembly for mathematical operations** - Reduce gas costs by 20-30%
2. **Pack struct variables** - Minimize storage slot usage
3. **Implement view functions** - Allow off-chain calculations
4. **Batch operations** - Combine multiple operations in single transaction
5. **Optimize oracle calls** - Cache oracle prices within same block

## Security Considerations

- **Oracle manipulation protection**: Implement price deviation checks
- **MEV protection**: Consider commit-reveal schemes for large swaps
- **Reentrancy guards**: Protect all state-changing functions
- **Access controls**: Implement role-based permissions
- **Emergency pauses**: Add circuit breakers for extreme conditions
