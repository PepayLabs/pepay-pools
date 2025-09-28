// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {HyperCoreConstants} from "../../contracts/oracle/HyperCoreConstants.sol";

contract OracleAdapterHCPrecompileAddressesTest is Test {
    function test_markPxPrecompilePinned() external {
        assertEq(HyperCoreConstants.MARK_PX_PRECOMPILE, address(0x0806), "mark precompile");
    }

    function test_oraclePxPrecompilePinned() external {
        assertEq(HyperCoreConstants.ORACLE_PX_PRECOMPILE, address(0x0807), "oracle precompile");
    }

    function test_spotPxPrecompilePinned() external {
        assertEq(HyperCoreConstants.SPOT_PX_PRECOMPILE, address(0x0808), "spot precompile");
    }

    function test_bboPrecompilePinned() external {
        assertEq(HyperCoreConstants.BBO_PRECOMPILE, address(0x080e), "bbo precompile");
    }
}
