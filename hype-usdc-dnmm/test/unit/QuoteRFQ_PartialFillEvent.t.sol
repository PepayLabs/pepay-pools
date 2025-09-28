// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {Vm} from "forge-std/Vm.sol";

contract QuoteRFQPartialFillEventTest is BaseTest {
    QuoteRFQ internal rfq;
    uint256 internal makerKey;
    address internal makerAddr;

    bytes32 internal constant QUOTE_FILLED_SIG =
        keccak256("QuoteFilled(address,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

    function setUp() public {
        setUpBase();
        (makerKey, makerAddr) = _loadMakerSigner();
        rfq = new QuoteRFQ(address(pool), makerAddr);
        approveAll(alice);
        approveAll(bob);

        // ensure taker inventory is sufficient to cover large partial-fill requests
        hype.transfer(alice, 500_000 ether);

        vm.prank(alice);
        hype.approve(address(rfq), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(rfq), type(uint256).max);
    }

    function test_eventEmitsActualFillData() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 400_000 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 180,
            salt: 404
        });

        bytes memory sig = _sign(params);

        vm.recordLogs();
        vm.prank(alice);
        uint256 poolAmountOut = rfq.verifyAndSwap(sig, params, bytes(""));

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.topics.length == 0 || entry.topics[0] != QUOTE_FILLED_SIG) continue;
            if (entry.topics[1] != bytes32(uint256(uint160(alice)))) continue;
            (
                bool isBaseIn,
                uint256 requestedAmountIn,
                uint256 amountOutEvent,
                uint256 expiry,
                uint256 salt,
                uint256 actualAmountIn,
                uint256 actualAmountOut,
                uint256 leftoverReturned
            ) = abi.decode(entry.data, (bool, uint256, uint256, uint256, uint256, uint256, uint256, uint256));

            assertTrue(isBaseIn, "base in");
            assertEq(requestedAmountIn, params.amountIn, "requested amount");
            assertEq(expiry, params.expiry, "expiry");
            assertEq(salt, params.salt, "salt");
            assertEq(amountOutEvent, poolAmountOut, "amount out");
            assertEq(actualAmountOut, poolAmountOut, "actual out");
            assertEq(actualAmountIn + leftoverReturned, params.amountIn, "conservation");
            assertGt(leftoverReturned, 0, "leftover returned");
            found = true;
            break;
        }
        assertTrue(found, "QuoteFilled event emitted");
    }

    function _sign(IQuoteRFQ.QuoteParams memory params) internal view returns (bytes memory) {
        bytes32 digest = rfq.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _loadMakerSigner() internal view returns (uint256 key, address addr) {
        key = _loadSignerKey();
        addr = vm.addr(key);
        try vm.envAddress("RFQ_SIGNER_ADDR") returns (address envAddr) {
            require(envAddr == addr, "RFQ_SIGNER_MISMATCH");
            addr = envAddr;
        } catch {}
    }

    function _loadSignerKey() internal view returns (uint256 key) {
        try vm.envUint("RFQ_SIGNER_PK") returns (uint256 envKey) {
            key = envKey;
        } catch {
            key = 0xA11ce;
        }
    }
}
