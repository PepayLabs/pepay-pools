// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {Errors} from "../../contracts/lib/Errors.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract ReadOracleMidUnsetCoverageTest is BaseTest {
    function setUp() public {
        setUpBase();

        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        cfg.allowEmaFallback = false;
        cfg.maxAgeSec = 120;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Oracle, abi.encode(cfg));

        DnmPool.PreviewConfig memory previewCfg = defaultPreviewConfig();
        previewCfg.enablePreviewFresh = true;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Preview, abi.encode(previewCfg));
    }

    function test_midUnsetRevertsOnQuoteAndPreview() public {
        oracleHC.setSpot(0, 0, false);
        oracleHC.setBidAsk(0, 0, 0, false);
        oracleHC.setEma(0, 0, false);

        IOracleAdapterPyth.PythResult memory res = IOracleAdapterPyth.PythResult({
            hypeUsd: 0,
            usdcUsd: 0,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 0,
            confBpsUsdc: 0,
            success: false
        });
        oraclePyth.setResult(res);

        vm.prank(alice);
        vm.expectRevert(Errors.MidUnset.selector);
        pool.quoteSwapExactIn(1 ether, true, IDnmPool.OracleMode.Spot, bytes(""));

        uint256[] memory ladder = new uint256[](1);
        ladder[0] = 1e18;

        vm.expectRevert(Errors.MidUnset.selector);
        pool.previewFeesFresh(IDnmPool.OracleMode.Spot, bytes(""), ladder);
    }
}
