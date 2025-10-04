// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract LvrFeeRespectsCapsTest is BaseTest {
    function setUp() public {
        setUpBase();

        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.baseBps = 0;
        feeCfg.capBps = 500;
        feeCfg.gammaSizeLinBps = 0;
        feeCfg.gammaSizeQuadBps = 0;
        feeCfg.sizeFeeCapBps = 0;
        feeCfg.kappaLvrBps = 2_000; // aggressive coefficient; cap should still bound fee
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Fee, abi.encode(feeCfg));

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.blendOn = true;
        flags.enableLvrFee = true;
        flags.enableSizeFee = false;
        flags.enableBboFloor = false;
        flags.enableInvTilt = false;
        flags.enableAOMQ = false;
        setFeatureFlags(flags);

        updateSpot(1e18, 0, true);
        updateBidAsk(950e15, 1050e15, 100, true); // 10% spread to pump sigma
        updatePyth(1e18, 1e18, 0, 0, 200, 200);
        rollBlocks(1);
    }

    function test_lvrFeeNeverExceedsCap() public {
        IDnmPool.QuoteResult memory res = quote(20_000 ether, true, IDnmPool.OracleMode.Spot);
        assertLe(res.feeBpsUsed, 500, "fee capped by policy");
    }
}
