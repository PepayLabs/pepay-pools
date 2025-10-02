// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {EventRecorder} from "../utils/EventRecorder.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {IOracleAdapterPyth} from "../../contracts/interfaces/IOracleAdapterPyth.sol";
import {Errors} from "../../contracts/lib/Errors.sol";

contract FailurePathGasTest is BaseTest {
    uint256 private constant FLOOR_CAP = 150_000;
    uint256 private constant STALE_CAP = 120_000;
    uint256 private constant DIVERGENCE_CAP = 120_000;

    function setUp() public {
        setUpBase();
        approveAll(address(this));
    }

    function test_failure_path_gas_caps() public {
        string[] memory rows = new string[](3);

        uint256 gasFloor = _measureFloorBreach();
        assertLe(gasFloor, FLOOR_CAP, "floor breach gas cap");
        rows[0] = _formatRow("floor_breach", gasFloor, FLOOR_CAP);

        uint256 gasStale = _measureStaleOracle();
        assertLe(gasStale, STALE_CAP, "stale oracle gas cap");
        rows[1] = _formatRow("oracle_stale", gasStale, STALE_CAP);

        uint256 gasDivergence = _measureDivergenceReject();
        assertLe(gasDivergence, DIVERGENCE_CAP, "divergence gas cap");
        rows[2] = _formatRow("divergence_reject", gasDivergence, DIVERGENCE_CAP);

        EventRecorder.writeCSV(vm, "metrics/gas_dos_failures.csv", "case,gas_used,cap", rows);
    }

    function _measureFloorBreach() internal returns (uint256 gasUsed) {
        _resetPool();

        updateSpot(1e18, 2, true);
        updateBidAsk(998e15, 1_002e15, 20, true);
        updateEma(1e18, 2, true);

        uint256 quoteBalance = usdc.balanceOf(address(pool));
        if (quoteBalance > 0) {
            vm.prank(address(pool));
            usdc.transfer(address(0xdead), quoteBalance);
            pool.sync();
            require(usdc.balanceOf(address(pool)) == 0, "quote balance check");
        }

        bytes memory callData = abi.encodeWithSelector(
            DnmPool.swapExactIn.selector, 1 ether, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1
        );
        (uint256 used, bool success, bytes memory ret) = _call(address(pool), callData);
        require(!success, "floor breach should revert");
        require(_revertMatches(ret, Errors.FloorBreach.selector), "floor breach reason");
        return used;
    }

    function _measureStaleOracle() internal returns (uint256 gasUsed) {
        _resetPool();

        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        cfg.allowEmaFallback = false;
        cfg.maxAgeSec = 30;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Oracle, abi.encode(cfg));

        // make spot stale and disable Pyth
        updateSpot(1e18, 120, true);
        updateEma(0, 0, false);
        IOracleAdapterPyth.PythResult memory emptyPyth = IOracleAdapterPyth.PythResult({
            hypeUsd: 0,
            usdcUsd: 0,
            ageSecHype: 0,
            ageSecUsdc: 0,
            confBpsHype: 0,
            confBpsUsdc: 0,
            success: false
        });
        oraclePyth.setResult(emptyPyth);

        bytes memory callData = abi.encodeWithSelector(
            DnmPool.quoteSwapExactIn.selector, 5 ether, true, IDnmPool.OracleMode.Spot, bytes("")
        );
        (uint256 used, bool success, bytes memory ret) = _call(address(pool), callData);
        require(!success, "stale oracle should revert");
        require(_revertMatches(ret, Errors.OracleStale.selector), "stale oracle reason");
        return used;
    }

    function _measureDivergenceReject() internal returns (uint256 gasUsed) {
        _resetPool();

        DnmPool.OracleConfig memory cfg = defaultOracleConfig();
        cfg.divergenceBps = 25;
        cfg.allowEmaFallback = false;
        vm.prank(gov);
        pool.updateParams(IDnmPool.ParamKind.Oracle, abi.encode(cfg));

        updateSpot(1e18, 2, true);
        updateBidAsk(998e15, 1_002e15, 20, true);
        updateEma(1e18, 2, true);
        updatePyth(1_500_000_000_000_000_000, 1e18, 0, 0, 20, 20);

        bytes memory callData = abi.encodeWithSelector(
            DnmPool.quoteSwapExactIn.selector, 5 ether, true, IDnmPool.OracleMode.Spot, bytes("")
        );
        (uint256 used, bool success, bytes memory ret) = _call(address(pool), callData);
        require(!success, "divergence should revert");
        require(_revertMatches(ret, Errors.OracleDiverged.selector), "divergence reason");
        return used;
    }

    function _resetPool() internal {
        DnmPool.InventoryConfig memory invCfg = defaultInventoryConfig();
        DnmPool.OracleConfig memory oracleCfg = defaultOracleConfig();
        DnmPool.MakerConfig memory makerCfg = defaultMakerConfig();
        redeployPool(invCfg, oracleCfg, defaultFeeConfig(), makerCfg, defaultAomqConfig());
        seedPOL(
            DeployConfig({
                baseLiquidity: 100_000 ether,
                quoteLiquidity: 10_000_000000,
                floorBps: invCfg.floorBps,
                recenterPct: invCfg.recenterThresholdPct,
                divergenceBps: oracleCfg.divergenceBps,
                allowEmaFallback: oracleCfg.allowEmaFallback
            })
        );
        approveAll(address(this));
        _setOracleDefaults();
    }

    function _call(address target, bytes memory data)
        internal
        returns (uint256 gasUsed, bool success, bytes memory ret)
    {
        uint256 gasBefore = gasleft();
        (success, ret) = target.call(data);
        uint256 gasAfter = gasleft();
        gasUsed = gasBefore - gasAfter;
    }

    function _revertMatches(bytes memory ret, bytes4 expectedSelector) internal pure returns (bool) {
        if (ret.length < 4) return false;
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(ret, 0x20))
        }
        return selector == expectedSelector;
    }

    function _formatRow(string memory label, uint256 gasUsed, uint256 cap) internal pure returns (string memory) {
        return string.concat(label, ",", EventRecorder.uintToString(gasUsed), ",", EventRecorder.uintToString(cap));
    }
}
