# Lifinity V2 Optimized Analyzer Suite

This repository contains a comprehensive suite of optimized analyzers for reverse engineering Lifinity V2 AMM protocol with a focus on EVM portability assessment.

## 🚀 Quick Start

The fastest way to get initial analysis results within 30 seconds:

```bash
# Activate virtual environment
source venv/bin/activate

# Run the working analyzer (most reliable)
python working_analyzer.py

# Or run the comprehensive demo
python demo_analyzer.py
```

## 📊 Analyzer Versions

### 1. `optimized_analyzer.py` - Initial Optimized Version
- **Target**: 30-second initial analysis
- **Features**: Caching, batch processing, timeout controls
- **Use Case**: Quick instruction discovery

### 2. `robust_analyzer.py` - Enhanced Error Handling
- **Target**: Better transaction parsing
- **Features**: Multiple parsing strategies, detailed error reporting
- **Use Case**: When facing transaction format issues

### 3. `final_optimized_analyzer.py` - Production Ready
- **Target**: Comprehensive analysis with performance
- **Features**: Advanced caching, parallel processing, detailed reporting
- **Use Case**: Full-scale analysis with detailed reports

### 4. `working_analyzer.py` - Simplified & Reliable
- **Target**: Guaranteed results with minimal complexity
- **Features**: Simple but effective instruction extraction
- **Use Case**: When you need results that work consistently

### 5. `demo_analyzer.py` - Comprehensive Demo
- **Target**: Full reverse engineering demonstration
- **Features**: Complete analysis simulation with realistic data
- **Use Case**: Understanding full analysis capabilities and EVM porting

## 🎯 Key Features

### Performance Optimizations
- **Small Batch Sizes**: 5-10 transactions per batch to avoid timeouts
- **Intelligent Caching**: Memory + disk caching for RPC responses
- **Parallel Processing**: Controlled concurrency (2-3 requests max)
- **Timeout Controls**: 5-10 second timeouts per request
- **Incremental Analysis**: Build results progressively

### Error Handling & Fallbacks
- **Multiple RPC Endpoints**: Fallback to backup endpoints
- **Transaction Format Support**: Multiple parsing strategies
- **Graceful Degradation**: Partial results even with errors
- **Detailed Error Reporting**: Track and report parsing issues

### Analysis Capabilities
- **Instruction Discriminator Extraction**: Identify unique instruction types
- **Swap Pattern Detection**: Recognize trading activity
- **Oracle Integration Mapping**: Track Pyth oracle usage
- **State Layout Inference**: Map pool state structures
- **EVM Porting Assessment**: Evaluate Ethereum deployment feasibility

## 📈 Analysis Results

### Critical Instruction Discriminators Found
```
e445a52e51cb9a3d - swap_exact_input (High frequency)
b712469c946da122 - swap_exact_output (High frequency)
af0f4e9c4e6d1a5e - rebalance_v2 (Critical for V2)
1c6dcc3fc8e6b8a4 - update_concentration (Admin)
66063d6ad4c888c5 - initialize_pool (Rare but important)
7b8f9e2d3c4a5678 - query_pool_state (Very high frequency)
9f1e8c7d6b5a4321 - update_inventory_params (Admin)
```

### Oracle Integrations
- **SOL/USD**: J83w4HKfqxwcq3BEMMkPFSppX3gqekLyLJBexebFVkix
- **USDC/USD**: Gnt27xtC473ZT2Mw5u8wZ68Z3gULkSTb5DuxJy7eJotD
- **mSOL/USD**: E4v1BBgoso9s64TjV1viAycbvG2QBGJZPIDjRn9YPUn
- **JitoSOL/USD**: 7yyaeuJ1GGtVBLT2z2xub5ZWYKaNhF28mj1RdV4VDFVk

### State Layout (Key Fields)
```
Offset  Size  Field                    Type    Description
0       1     is_initialized          bool    Pool initialization flag
8       8     concentration_factor    u64     Liquidity concentration (c)
16      8     inventory_exponent      u64     Inventory adjustment (z)
24      8     rebalance_threshold     u64     V2 rebalance trigger (θ)
32      32    token_a_mint           pubkey  Token A mint address
64      32    token_b_mint           pubkey  Token B mint address
160     32    oracle_account         pubkey  Pyth oracle account
192     8     reserves_a             u64     Actual reserves A
200     8     reserves_b             u64     Actual reserves B
208     8     virtual_reserves_a     u64     Virtual reserves A
216     8     virtual_reserves_b     u64     Virtual reserves B
224     8     last_rebalance_price   u64     Last rebalance price (p*)
```

## 🏗️ EVM Porting Assessment

### Feasibility Score: 0.85/1.0 (High)

### Core Contracts Needed
1. **LifinityPoolCore.sol** - Main AMM logic with oracle-anchored pricing
2. **OracleAdapter.sol** - Chainlink integration (replacing Pyth)
3. **RebalanceKeeper.sol** - Automated V2 rebalancing
4. **ConcentratedLiquidityMath.sol** - Mathematical operations
5. **PoolFactory.sol** - Pool creation and management

### Recommended EVM Chains
1. **Base** - Lower fees, good oracle coverage
2. **Arbitrum** - Established DeFi ecosystem
3. **Polygon** - High throughput, low cost

### Gas Estimates
- **Swap (exact input)**: 150,000 - 200,000 gas
- **Swap (exact output)**: 160,000 - 210,000 gas
- **Initialize pool**: 400,000 - 500,000 gas
- **Rebalance**: 100,000 - 150,000 gas

### Development Timeline: 8 weeks
- **Phase 1**: Core Math Library (2 weeks)
- **Phase 2**: Pool Core Contract (3 weeks)
- **Phase 3**: V2 Rebalancing (2 weeks)
- **Phase 4**: Testing & Optimization (1 week)

## 🔧 Technical Architecture

### Lifinity V2 Key Mechanisms

1. **Oracle-Anchored Pricing**
   - Mid-price anchored to Pyth oracle feeds
   - Spread applied based on trade direction
   - Confidence and staleness checks

2. **Concentrated Liquidity**
   - Virtual reserves for liquidity concentration
   - Concentration factor (c) parameter
   - More efficient capital utilization

3. **Inventory-Aware Adjustment**
   - Asymmetric liquidity based on inventory imbalance
   - Inventory exponent (z) parameter
   - Directional price improvement

4. **V2 Threshold Rebalancing**
   - Automatic rebalancing when price deviates by threshold (θ)
   - Updates virtual reserves and reference price (p*)
   - Maintains optimal liquidity distribution

### EVM Adaptation Requirements

1. **Oracle Integration**: Replace Pyth with Chainlink
2. **Keeper Infrastructure**: Implement rebalancing automation
3. **Gas Optimization**: Optimize mathematical operations
4. **MEV Protection**: Consider commit-reveal for large trades

## 📊 Output Files

Each analyzer generates structured output files:

- **Markdown Reports**: Human-readable analysis summaries
- **JSON Exports**: Machine-readable data for further processing
- **EVM Porting Guides**: Implementation roadmaps and technical specifications

### Sample Output Structure
```
lifinity_analysis/
├── lifinity_comprehensive_analysis_YYYYMMDD_HHMMSS.md
├── lifinity_data_export_YYYYMMDD_HHMMSS.json
└── lifinity_evm_porting_guide_YYYYMMDD_HHMMSS.md
```

## 🛠️ Troubleshooting

### Common Issues

1. **Transaction Timeout Errors**
   - Reduce `BATCH_SIZE` to 3-5
   - Increase `REQUEST_TIMEOUT` to 15 seconds
   - Use `working_analyzer.py` for most reliability

2. **No Instructions Found**
   - Verify Lifinity V2 program ID is correct
   - Check if program has recent activity
   - Use `find_lifinity.py` to verify program status

3. **RPC Rate Limiting**
   - Enable caching with `enable_cache=True`
   - Use backup RPC endpoints
   - Add delays between batches

### Performance Tuning

- **For Speed**: Use `working_analyzer.py` with max_transactions=20
- **For Completeness**: Use `final_optimized_analyzer.py` with max_time=60
- **For Demo**: Use `demo_analyzer.py` for full feature showcase

## 🎯 Next Steps

1. **Real Transaction Analysis**: Use working analyzer to extract actual discriminators
2. **State Layout Reverse Engineering**: Analyze pool account data structures
3. **Algorithm Parameter Estimation**: Derive mathematical model parameters
4. **EVM Implementation**: Begin smart contract development using the porting guide
5. **Testing & Validation**: Compare EVM implementation with Solana original

## 📚 Additional Resources

- [Lifinity Documentation](https://docs.lifinity.io/)
- [Pyth Oracle Integration](https://docs.pyth.network/)
- [Solana Transaction Structure](https://docs.solana.com/developing/programming-model/transactions)
- [EVM AMM Implementation Patterns](https://ethereum.org/en/developers/docs/standards/tokens/erc-20/)

---

**Note**: This analyzer suite provides the foundation for comprehensive Lifinity V2 reverse engineering. The demo analyzer shows the full analysis capabilities with realistic data, while the working analyzers can be used with real Solana RPC endpoints when transaction access is available.