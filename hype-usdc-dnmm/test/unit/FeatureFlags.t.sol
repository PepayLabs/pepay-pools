// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract FeatureFlagsTest is BaseTest {
    uint32 private constant FLAG_BLEND_ON = 1 << 0;
    uint32 private constant FLAG_PARITY_CI_ON = 1 << 1;
    uint32 private constant FLAG_DEBUG_EMIT = 1 << 2;
    uint32 private constant FLAG_ENABLE_SOFT_DIVERGENCE = 1 << 3;
    uint32 private constant FLAG_ENABLE_SIZE_FEE = 1 << 4;
    uint32 private constant FLAG_ENABLE_BBO_FLOOR = 1 << 5;
    uint32 private constant FLAG_ENABLE_INV_TILT = 1 << 6;
    uint32 private constant FLAG_ENABLE_AOMQ = 1 << 7;
    uint32 private constant FLAG_ENABLE_REBATES = 1 << 8;
    uint32 private constant FLAG_ENABLE_AUTO_RECENTER = 1 << 9;
    function setUp() public virtual {
        setUpBase();
    }

    function test_defaultFeatureFlagsAllDisabled() public view {
        (
            bool blendOn,
            bool parityCiOn,
            bool debugEmit,
            bool enableSoftDivergence,
            bool enableSizeFee,
            bool enableBboFloor,
            bool enableInvTilt,
            bool enableAOMQ,
            bool enableRebates,
            bool enableAutoRecenter
        ) = pool.featureFlags();

        assertFalse(blendOn, "blendOn should default disabled");
        assertFalse(parityCiOn, "parityCiOn should default disabled");
        assertFalse(debugEmit, "debugEmit should default disabled");
        assertFalse(enableSoftDivergence, "soft divergence flag default");
        assertFalse(enableSizeFee, "size fee flag default");
        assertFalse(enableBboFloor, "bbo floor flag default");
        assertFalse(enableInvTilt, "inventory tilt flag default");
        assertFalse(enableAOMQ, "AOMQ flag default");
        assertFalse(enableRebates, "rebates flag default");
        assertFalse(enableAutoRecenter, "auto recenter flag default");
        assertEq(pool.featureFlagMask(), 0, "mask should default disabled");
    }

    function test_governanceCanToggleFeatureFlags() public {
        DnmPool.FeatureFlags memory flags = DnmPool.FeatureFlags({
            blendOn: true,
            parityCiOn: true,
            debugEmit: false,
            enableSoftDivergence: true,
            enableSizeFee: true,
            enableBboFloor: true,
            enableInvTilt: true,
            enableAOMQ: true,
            enableRebates: true,
            enableAutoRecenter: true
        });

        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Feature, abi.encode(flags));

        (
            bool blendOn,
            bool parityCiOn,
            bool debugEmit,
            bool enableSoftDivergence,
            bool enableSizeFee,
            bool enableBboFloor,
            bool enableInvTilt,
            bool enableAOMQ,
            bool enableRebates,
            bool enableAutoRecenter
        ) = pool.featureFlags();

        assertTrue(blendOn, "blendOn enabled");
        assertTrue(parityCiOn, "parityCiOn enabled");
        assertFalse(debugEmit, "debug emit remains disabled");
        assertTrue(enableSoftDivergence, "soft divergence enabled");
        assertTrue(enableSizeFee, "size fee enabled");
        assertTrue(enableBboFloor, "bbo floor enabled");
        assertTrue(enableInvTilt, "inventory tilt enabled");
        assertTrue(enableAOMQ, "AOMQ enabled");
        assertTrue(enableRebates, "rebates enabled");
        assertTrue(enableAutoRecenter, "auto recenter enabled");

        uint32 expectedMask = FLAG_BLEND_ON
            | FLAG_PARITY_CI_ON
            | FLAG_ENABLE_SOFT_DIVERGENCE
            | FLAG_ENABLE_SIZE_FEE
            | FLAG_ENABLE_BBO_FLOOR
            | FLAG_ENABLE_INV_TILT
            | FLAG_ENABLE_AOMQ
            | FLAG_ENABLE_REBATES
            | FLAG_ENABLE_AUTO_RECENTER;
        assertEq(pool.featureFlagMask(), expectedMask, "mask should match enabled flags");
    }
}
