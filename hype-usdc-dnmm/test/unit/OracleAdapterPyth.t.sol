// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {OracleAdapterPyth} from "../../contracts/oracle/OracleAdapterPyth.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {MockPyth} from "../utils/Mocks.sol";

contract OracleAdapterPythTest is Test {
    OracleAdapterPyth internal adapter;
    MockPyth internal pyth;

    bytes32 internal constant HYPE_ID = keccak256("HYPE/USD");
    bytes32 internal constant USDC_ID = keccak256("USDC/USD");

    function setUp() public {
        vm.warp(1_000);
        pyth = new MockPyth();
        adapter = new OracleAdapterPyth(address(pyth), HYPE_ID, USDC_ID);

        pyth.setPrice(HYPE_ID, 25_123_000_000, -8, 50, uint64(block.timestamp - 4));
        pyth.setPrice(USDC_ID, 1_000_100_000, -8, 25, uint64(block.timestamp - 2));
    }

    function test_pairMid_from_two_feeds_ok() public {
        IOracleAdapterPyth.PythResult memory res = adapter.readPythUsdMid(bytes(""));
        assertTrue(res.success, "pyth success");
        (uint256 mid, uint256 age, uint256 conf) = adapter.computePairMid(res);
        assertGt(mid, 0, "mid");
        // expected mid roughly 25.120? ensure ratio matches on-chain math
        uint256 expectedMid = (res.hypeUsd * 1e18) / res.usdcUsd;
        assertEq(mid, expectedMid, "mid ratio");
        assertEq(age, 4, "age max");
        uint256 expectedConf = res.confBpsHype > res.confBpsUsdc ? res.confBpsHype : res.confBpsUsdc;
        assertEq(conf, expectedConf, "conf selection");
    }

    function test_pyth_confidence_caps() public {
        pyth.setPrice(HYPE_ID, 30_000_000_000, -8, 500, uint64(block.timestamp));
        pyth.setPrice(USDC_ID, 1_000_000_000, -8, 200, uint64(block.timestamp));

        IOracleAdapterPyth.PythResult memory res = adapter.readPythUsdMid(bytes(""));
        (,, uint256 conf) = adapter.computePairMid(res);
        uint256 expectedConf = res.confBpsHype > res.confBpsUsdc ? res.confBpsHype : res.confBpsUsdc;
        assertEq(conf, expectedConf, "conf selection");
    }

    function test_age_caps() public {
        pyth.setPrice(HYPE_ID, 20_000_000_000, -8, 40, uint64(block.timestamp - 100));
        pyth.setPrice(USDC_ID, 1_000_000_000, -8, 40, uint64(block.timestamp - 10));

        IOracleAdapterPyth.PythResult memory res = adapter.readPythUsdMid(bytes(""));
        (uint256 mid, uint256 age,) = adapter.computePairMid(res);
        assertTrue(res.success, "success");
        assertGt(age, 10, "age picks worst");
        assertEq(mid, (res.hypeUsd * 1e18) / res.usdcUsd, "mid matches ratio");
    }

    function test_failure_when_price_zero() public {
        pyth.setPrice(HYPE_ID, 0, -8, 0, uint64(block.timestamp));
        IOracleAdapterPyth.PythResult memory res = adapter.readPythUsdMid(bytes(""));
        assertFalse(res.success, "success flag");
        (uint256 mid,,) = adapter.computePairMid(res);
        assertEq(mid, 0, "mid zero");
    }
}
