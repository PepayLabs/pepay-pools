// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract QuoteRFQTest is BaseTest {
    QuoteRFQ internal rfq;
    uint256 internal makerKey = 0xA11ce;
    address internal makerAddr;

    function setUp() public {
        setUpBase();
        makerAddr = vm.addr(makerKey);
        rfq = new QuoteRFQ(address(pool), makerAddr);
        approveAll(alice);
        approveAll(bob);

        vm.prank(alice);
        hype.approve(address(rfq), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(rfq), type(uint256).max);
    }

    function test_verifyAndSwap_valid_signature_ttl() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 1_000 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 60,
            salt: 1
        });

        bytes memory sig = _sign(params);

        uint256 quoteBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 amountOut = rfq.verifyAndSwap(sig, params, bytes(""));

        assertGt(amountOut, 0, "amount out");
        assertGt(usdc.balanceOf(alice), quoteBefore, "alice received quote");
        assertTrue(rfq.consumedSalts(params.salt), "salt consumed");
    }

    function test_rfq_expired_reverts() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 100 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp - 1,
            salt: 2
        });
        bytes memory sig = _sign(params);

        vm.prank(alice);
        vm.expectRevert("RFQ_EXPIRED");
        rfq.verifyAndSwap(sig, params, bytes(""));
    }

    function test_rfq_wrong_signer_reverts() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 100 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 3
        });

        uint256 badKey = 0xBEEF;
        bytes32 digest = _hash(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        vm.expectRevert("BAD_SIG");
        rfq.verifyAndSwap(sig, params, bytes(""));
    }

    function test_rfq_replay_protection() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 100 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 4
        });
        bytes memory sig = _sign(params);

        vm.prank(alice);
        rfq.verifyAndSwap(sig, params, bytes(""));

        vm.prank(alice);
        vm.expectRevert("RFQ_USED");
        rfq.verifyAndSwap(sig, params, bytes(""));
    }

    function test_rfq_handles_large_order() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 10_000 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 5
        });
        bytes memory sig = _sign(params);

        vm.prank(alice);
        uint256 amountOut = rfq.verifyAndSwap(sig, params, bytes(""));
        assertGt(amountOut, 0, "amount out");
    }

    function _sign(IQuoteRFQ.QuoteParams memory params) internal returns (bytes memory) {
        bytes32 digest = _hash(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hash(IQuoteRFQ.QuoteParams memory params) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            "Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt,address pool,uint256 chainId)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                params.taker,
                params.amountIn,
                params.minAmountOut,
                params.isBaseIn,
                params.expiry,
                params.salt,
                address(pool),
                block.chainid
            )
        );
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
    }
}
