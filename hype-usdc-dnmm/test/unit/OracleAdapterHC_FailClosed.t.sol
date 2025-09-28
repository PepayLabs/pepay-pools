// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {OracleAdapterHC} from "../../contracts/oracle/OracleAdapterHC.sol";
import {HyperCoreConstants} from "../../contracts/oracle/HyperCoreConstants.sol";

contract HyperCoreReverter {
    fallback() external {
        revert("HC fail");
    }
}

contract HyperCoreShortReturn {
    fallback(bytes calldata data) external returns (bytes memory) {
        data;
        return abi.encodePacked(uint32(1));
    }
}

contract OracleAdapterHCFailClosedTest is Test {
    bytes32 internal constant ASSET_BASE = bytes32("HYPE");
    bytes32 internal constant ASSET_QUOTE = bytes32("USDC");
    bytes32 internal constant MARKET = bytes32("HYPE");

    function test_revertsWhenStaticcallFails() external {
        address core = address(new HyperCoreReverter());
        vm.etch(HyperCoreConstants.ORACLE_PX_PRECOMPILE, core.code);
        OracleAdapterHC adapter =
            new OracleAdapterHC(HyperCoreConstants.ORACLE_PX_PRECOMPILE, ASSET_BASE, ASSET_QUOTE, MARKET);

        bytes memory revertData = abi.encodeWithSignature("Error(string)", "HC fail");
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAdapterHC.HyperCoreCallFailed.selector, HyperCoreConstants.ORACLE_PX_PRECOMPILE, revertData
            )
        );
        adapter.readMidAndAge();
    }

    function test_revertsOnShortResponse() external {
        address core = address(new HyperCoreShortReturn());
        vm.etch(HyperCoreConstants.ORACLE_PX_PRECOMPILE, core.code);
        OracleAdapterHC adapter =
            new OracleAdapterHC(HyperCoreConstants.ORACLE_PX_PRECOMPILE, ASSET_BASE, ASSET_QUOTE, MARKET);

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAdapterHC.HyperCoreInvalidResponse.selector, HyperCoreConstants.ORACLE_PX_PRECOMPILE, uint256(4)
            )
        );
        adapter.readMidAndAge();
    }
}
