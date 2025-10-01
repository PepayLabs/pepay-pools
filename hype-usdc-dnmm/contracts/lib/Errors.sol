// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Errors {
    error PoolPaused();
    error NotGovernance();
    error NotPauser();
    error DeadlineExpired();
    error OracleStale();
    error OracleSpread();
    error OracleDiverged(uint256 deltaBps, uint256 maxBps);
    error InvalidOrderbook();
    error InvalidTimestamp();
    error TokenFeeUnsupported();
    error FloorBreach();
    error ZeroAmount();
    error InvalidConfig();
    error TokensZero();
    error GovernanceZero();
    error InvalidParamKind();
    error Slippage();
    error BaseOverflow();
    error QuoteOverflow();
    error InsufficientQuoteReserves();
    error InsufficientBaseReserves();
    error MidUnset();
    error RecenterThreshold();
    error RecenterCooldown();
    error FeeCapExceeded();
    error FeePreviewInvariant();
    error DivergenceHard(uint256 deltaBps, uint256 hardBps);
}
