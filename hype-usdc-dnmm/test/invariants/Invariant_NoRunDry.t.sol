// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {DnmPool} from "../../contracts/DnmPool.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {MockOracleHC} from "../../contracts/mocks/MockOracleHC.sol";
import {MockOraclePyth} from "../../contracts/mocks/MockOraclePyth.sol";
import {Inventory} from "../../contracts/lib/Inventory.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract InvariantNoRunDry is StdInvariant, BaseTest {
    Handler internal handler;
    uint256 internal baseInitial;
    uint256 internal quoteInitial;

    function setUp() public {
        setUpBase();
        approveAll(alice);
        approveAll(bob);

        (uint128 baseRes, uint128 quoteRes) = pool.reserves();
        baseInitial = baseRes;
        quoteInitial = quoteRes;

        handler = new Handler(pool, hype, usdc, oracleHC, oraclePyth);
        hype.transfer(address(handler), 200_000 ether);
        usdc.transfer(address(handler), 5_000_000000);
        targetContract(address(handler));
    }

    function invariant_never_runs_dry() public view {
        (uint128 baseRes, uint128 quoteRes) = pool.reserves();
        (, uint16 floorBps,) = pool.inventoryConfig();
        uint256 baseFloor = Inventory.floorAmount(uint256(baseRes), floorBps);
        uint256 quoteFloor = Inventory.floorAmount(uint256(quoteRes), floorBps);
        assertGe(uint256(baseRes), baseFloor, "base below floor");
        assertGe(uint256(quoteRes), quoteFloor, "quote below floor");
    }
}

contract Handler {
    DnmPool public pool;
    MockERC20 public base;
    MockERC20 public quote;
    MockOracleHC public oracleHC;
    MockOraclePyth public oraclePyth;

    constructor(DnmPool pool_, MockERC20 base_, MockERC20 quote_, MockOracleHC oracleHC_, MockOraclePyth oraclePyth_) {
        pool = pool_;
        base = base_;
        quote = quote_;
        oracleHC = oracleHC_;
        oraclePyth = oraclePyth_;

        base.approve(address(pool), type(uint256).max);
        quote.approve(address(pool), type(uint256).max);
    }

    function swapBaseIn(uint256 amount) external {
        amount = _bound(amount, 1e6, 40_000 ether);
        uint256 balance = base.balanceOf(address(this));
        if (balance == 0) return;
        if (amount > balance) amount = balance;
        try pool.quoteSwapExactIn(amount, true, IDnmPool.OracleMode.Spot, bytes("")) returns (DnmPool.QuoteResult memory) {
            pool.swapExactIn(amount, 0, true, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        } catch {
            return;
        }
    }

    function swapQuoteIn(uint256 amount) external {
        amount = _bound(amount, 1e3, 1_200_000000);
        uint256 balance = quote.balanceOf(address(this));
        if (balance == 0) return;
        if (amount > balance) amount = balance;
        try pool.quoteSwapExactIn(amount, false, IDnmPool.OracleMode.Spot, bytes("")) returns (DnmPool.QuoteResult memory) {
            pool.swapExactIn(amount, 0, false, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
        } catch {
            return;
        }
    }

    function updateOracle(uint256 mid, uint256 spreadBps, uint256 age) external {
        mid = _bound(mid, 9e17, 11e17);
        spreadBps = _bound(spreadBps, 10, 500);
        age = _bound(age, 0, 120);
        oracleHC.setSpot(mid, age, true);
        uint256 bid = mid - (mid * spreadBps) / (2 * 10_000);
        uint256 ask = mid + (mid * spreadBps) / (2 * 10_000);
        oracleHC.setBidAsk(bid, ask, spreadBps, true);
    }

    function _bound(uint256 value, uint256 minVal, uint256 maxVal) internal pure returns (uint256) {
        if (value < minVal) return minVal;
        if (value > maxVal) return maxVal;
        return value;
    }
}
