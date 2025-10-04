// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";

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
            bool enableAutoRecenter,
            bool enableLvrFee
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
        assertFalse(enableLvrFee, "LVR fee flag default");
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
            enableAutoRecenter: true,
            enableLvrFee: true
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
            bool enableAutoRecenter,
            bool enableLvrFee
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
        assertTrue(enableLvrFee, "LVR fee enabled");
    }

    function test_debugEmitFlagGatesConfidenceEvent() public {
        vm.recordLogs();
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 debugSig =
            keccak256("ConfidenceDebug(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == debugSig) {
                found = true;
                break;
            }
        }
        assertFalse(found, "debug event suppressed when flag off");

        DnmPool.FeatureFlags memory flags = getFeatureFlags();
        flags.debugEmit = true;
        setFeatureFlags(flags);

        found = false;
        vm.recordLogs();
        quote(10 ether, true, IDnmPool.OracleMode.Spot);
        logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == debugSig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "debug event fires when flag enabled");
    }
}
