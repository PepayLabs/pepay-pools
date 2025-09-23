// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract QuoteRFQTest is BaseTest {
    QuoteRFQ internal rfq;
    uint256 internal makerKey;
    address internal makerAddr;

    function setUp() public {
        setUpBase();
        (makerKey, makerAddr) = _loadMakerSigner();
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

    function test_hash_and_verify_signature() public view {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 20 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 60,
            salt: 10
        });

        bytes32 structHash = rfq.hashQuote(params);
        bytes32 digest = rfq.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes32 typeHash = keccak256(
            "Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt)"
        );
        bytes32 expectedStruct = keccak256(
            abi.encode(
                typeHash,
                params.taker,
                params.amountIn,
                params.minAmountOut,
                params.isBaseIn,
                params.expiry,
                params.salt
            )
        );
        assertEq(structHash, expectedStruct, "struct hash");
        assertEq(digest, rfq.hashTypedDataV4(params), "digest stable");
        assertTrue(rfq.verifyQuoteSignature(makerAddr, params, sig), "signature should verify");
    }

    function test_verify_quote_signature_rejects_tampered_amount() public view {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 50 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 60,
            salt: 11
        });

        bytes memory sig = _sign(params);
        params.amountIn += 1 ether;

        assertFalse(rfq.verifyQuoteSignature(makerAddr, params, sig), "tampered amount");
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
        vm.expectRevert(QuoteRFQ.QuoteExpired.selector);
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
        bytes32 digest = rfq.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(alice);
        vm.expectRevert(QuoteRFQ.QuoteSignerMismatch.selector);
        rfq.verifyAndSwap(sig, params, bytes(""));
    }

    function test_rfq_wrong_domain_reverts() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 75 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 6
        });

        QuoteRFQ other = new QuoteRFQ(address(pool), makerAddr);
        bytes memory sig = _signWith(params, other);

        vm.prank(alice);
        vm.expectRevert(QuoteRFQ.QuoteSignerMismatch.selector);
        rfq.verifyAndSwap(sig, params, bytes(""));
    }

    function test_rfq_wrong_chain_reverts() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 80 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 7
        });
        bytes memory sig = _sign(params);

        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 10);

        vm.prank(alice);
        vm.expectRevert(QuoteRFQ.QuoteSignerMismatch.selector);
        rfq.verifyAndSwap(sig, params, bytes(""));

        vm.chainId(originalChainId);
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
        vm.expectRevert(QuoteRFQ.QuoteAlreadyFilled.selector);
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

    function _sign(IQuoteRFQ.QuoteParams memory params) internal view returns (bytes memory) {
        bytes32 digest = rfq.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signWith(IQuoteRFQ.QuoteParams memory params, QuoteRFQ target) internal view returns (bytes memory) {
        bytes32 digest = target.hashTypedDataV4(params);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _loadMakerSigner() internal view returns (uint256 key, address addr) {
        key = _loadSignerKey();
        address derivedAddr = vm.addr(key);
        addr = derivedAddr;
        try vm.envAddress("RFQ_SIGNER_ADDR") returns (address envAddr) {
            require(envAddr == derivedAddr, "RFQ_SIGNER_MISMATCH");
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
