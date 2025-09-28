// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HyperCoreConstants
/// @notice Canonical selectors and addresses for HyperCore oracle precompiles.
/// @dev Values pinned against "Interacting with HyperCore" documentation (retrieved September 28, 2025).
library HyperCoreConstants {
    // Precompile exposes oracle entrypoints via staticcall at this address.
    // AUDIT:HCABI-001 single source of truth for HyperCore oracle endpoint
    address internal constant ORACLE_PRECOMPILE = address(0x0807);

    // Function signatures published in HyperCore ABI (L1Read.sol). Selectors are keccak256 hashes.
    // AUDIT:HCABI-001 pinned selector for spot mid + timestamp fetch
    bytes4 internal constant SEL_GET_SPOT_ORACLE_PRICE = bytes4(0x6e4677ff); // getSpotOraclePrice(bytes32,bytes32)

    // AUDIT:HCABI-001 pinned selector for top-of-book bid/ask fetch
    bytes4 internal constant SEL_GET_TOP_OF_BOOK = bytes4(0xc75e61ea); // getTopOfBook(bytes32)

    // AUDIT:HCABI-001 pinned selector for EMA mid oracle
    bytes4 internal constant SEL_GET_EMA_ORACLE_PRICE = bytes4(0x492524ab); // getEmaOraclePrice(bytes32,bytes32)
}

