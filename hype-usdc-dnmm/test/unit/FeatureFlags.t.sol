// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract FeatureFlagsTest is BaseTest {
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
        pool.updateParams(DnmPool.ParamKind.Feature, abi.encode(flags));

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
    }
}
