// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {OracleAdapterHC} from "../../contracts/oracle/OracleAdapterHC.sol";
import {HyperCoreConstants} from "../../contracts/oracle/HyperCoreConstants.sol";

contract HyperCoreReverter {
    fallback(bytes calldata) external pure {
        revert("HC fail");
    }
}

contract HyperCoreShortReturn {
    fallback(bytes calldata data) external pure returns (bytes memory) {
        data;
        return abi.encode(uint256(1));
    }
}

contract OracleAdapterHCFailClosedTest is Test {
    bytes32 internal constant ASSET_BASE = keccak256("HYPE");
    bytes32 internal constant ASSET_QUOTE = keccak256("USDC");
    bytes32 internal constant MARKET = keccak256("HYPE/USDC");

    function test_revertsWhenStaticcallFails() external {
        HyperCoreReverter core = new HyperCoreReverter();
        OracleAdapterHC adapter = new OracleAdapterHC(address(core), ASSET_BASE, ASSET_QUOTE, MARKET);

        bytes memory revertData = abi.encodeWithSignature("Error(string)", "HC fail");
        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAdapterHC.HyperCoreCallFailed.selector,
                HyperCoreConstants.SEL_GET_SPOT_ORACLE_PRICE,
                revertData
            )
        );
        adapter.readMidAndAge();
    }

    function test_revertsOnShortResponse() external {
        HyperCoreShortReturn core = new HyperCoreShortReturn();
        OracleAdapterHC adapter = new OracleAdapterHC(address(core), ASSET_BASE, ASSET_QUOTE, MARKET);

        vm.expectRevert(
            abi.encodeWithSelector(
                OracleAdapterHC.HyperCoreInvalidResponse.selector,
                HyperCoreConstants.SEL_GET_SPOT_ORACLE_PRICE,
                uint256(32)
            )
        );
        adapter.readMidAndAge();
    }
}

