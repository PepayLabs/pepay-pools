// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {HyperCoreConstants} from "../../contracts/oracle/HyperCoreConstants.sol";

contract OracleAdapterHCSelectorsTest is Test {
    function test_spotSelectorPinned() external {
        bytes4 expected = bytes4(keccak256("getSpotOraclePrice(bytes32,bytes32)"));
        assertEq(HyperCoreConstants.SEL_GET_SPOT_ORACLE_PRICE, expected, "spot selector");
    }

    function test_orderbookSelectorPinned() external {
        bytes4 expected = bytes4(keccak256("getTopOfBook(bytes32)"));
        assertEq(HyperCoreConstants.SEL_GET_TOP_OF_BOOK, expected, "book selector");
    }

    function test_emaSelectorPinned() external {
        bytes4 expected = bytes4(keccak256("getEmaOraclePrice(bytes32,bytes32)"));
        assertEq(HyperCoreConstants.SEL_GET_EMA_ORACLE_PRICE, expected, "ema selector");
    }

    function test_oraclePrecompileAddressPinned() external {
        assertEq(HyperCoreConstants.ORACLE_PRECOMPILE, address(0x0807), "oracle precompile address");
    }
}

