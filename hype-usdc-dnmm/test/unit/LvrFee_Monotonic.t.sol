// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {FeePolicy} from "../../contracts/lib/FeePolicy.sol";
import {FixedPointMath} from "../../contracts/lib/FixedPointMath.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract LvrFeeMonotonicTest is BaseTest {
    uint256 internal constant MID = 1e18;

    function setUp() public {
        setUpBase();

        FeePolicy.FeeConfig memory feeCfg = defaultFeeConfig();
        feeCfg.baseBps = 0;
        feeCfg.capBps = 900;
        feeCfg.gammaSizeLinBps = 0;
        feeCfg.gammaSizeQuadBps = 0;
        feeCfg.sizeFeeCapBps = 0;
        feeCfg.kappaLvrBps = 800;
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

        updateSpot(MID, 0, true);
        updateBidAsk(_bidFromSpread(MID, 10), _askFromSpread(MID, 10), 10, true);
        updatePyth(MID, MID, 0, 0, 10, 10);
    }

    function test_sigmaIncreaseRaisesFee() public {
        uint16 baselineFee = _quoteFee();

        // widen spread to drive sigma higher
        updateBidAsk(_bidFromSpread(MID, 60), _askFromSpread(MID, 60), 60, true);
        updatePyth(MID, MID, 0, 0, 30, 30);

        // allow sigma EWMA to update on next quote
        rollBlocks(1);
        uint16 elevatedFee = _quoteFee();

        assertGt(elevatedFee, baselineFee, "lvr fee should grow with sigma");
    }

    function test_ttlIncreaseRaisesFee() public {
        uint16 baselineFee = _quoteFee();

        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        makerCfg.ttlMs = 3_000; // 3.0 seconds vs 0.3 baseline
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Maker, abi.encode(makerCfg));

        rollBlocks(1);
        uint16 ttlFee = _quoteFee();
        assertGt(ttlFee, baselineFee, "longer TTL should raise LVR fee");
    }

    function _quoteFee() internal returns (uint16) {
        IDnmPool.QuoteResult memory result = quote(5_000 ether, true, IDnmPool.OracleMode.Spot);
        return uint16(result.feeBpsUsed);
    }

    function _bidFromSpread(uint256 mid, uint256 spreadBps) internal pure returns (uint256) {
        uint256 delta = FixedPointMath.mulDivDown(mid, spreadBps, 20_000);
        return mid > delta ? mid - delta : 1;
    }

    function _askFromSpread(uint256 mid, uint256 spreadBps) internal pure returns (uint256) {
        uint256 delta = FixedPointMath.mulDivUp(mid, spreadBps, 20_000);
        return mid + delta;
    }
}
