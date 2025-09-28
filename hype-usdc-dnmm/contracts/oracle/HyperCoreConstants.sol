// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title HyperCoreConstants
/// @notice Canonical addresses for HyperCore read precompiles on HyperEVM.
/// @dev Values pinned against "Interacting with HyperCore" documentation (retrieved September 28, 2025).
library HyperCoreConstants {
    // AUDIT:HCABI-001 single source of truth for HyperCore oracle endpoints (raw 32-byte I/O).
    address internal constant MARK_PX_PRECOMPILE = address(0x0806);
    address internal constant ORACLE_PX_PRECOMPILE = address(0x0807);
    address internal constant SPOT_PX_PRECOMPILE = address(0x0808);
    address internal constant BBO_PRECOMPILE = address(0x080e);
}
