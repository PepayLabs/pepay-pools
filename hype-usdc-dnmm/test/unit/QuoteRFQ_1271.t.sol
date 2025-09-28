// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {QuoteRFQ} from "../../contracts/quotes/QuoteRFQ.sol";
import {IQuoteRFQ} from "../../contracts/interfaces/IQuoteRFQ.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract Mock1271Signer {
    bytes32 public expectedDigest;
    bytes32 public expectedSignatureHash;
    bool public shouldRevert;
    bool public invalidMagic;

    function program(bytes32 digest, bytes calldata signature, bool revertCall, bool invalid) external {
        expectedDigest = digest;
        expectedSignatureHash = keccak256(signature);
        shouldRevert = revertCall;
        invalidMagic = invalid;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (shouldRevert) revert("no 1271");
        if (hash != expectedDigest || keccak256(signature) != expectedSignatureHash) {
            return 0x00000000;
        }
        return invalidMagic ? bytes4(0x00000000) : bytes4(0x1626ba7e);
    }
}

contract No1271 {
    fallback() external {
        revert("no 1271");
    }
}

contract QuoteRFQ1271Test is BaseTest {
    QuoteRFQ internal rfq;
    Mock1271Signer internal makerContract;

    function setUp() public {
        setUpBase();
        makerContract = new Mock1271Signer();
        rfq = new QuoteRFQ(address(pool), address(makerContract));
        approveAll(alice);
        approveAll(bob);

        vm.prank(alice);
        hype.approve(address(rfq), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(rfq), type(uint256).max);
    }

    function test_1271SignatureSucceeds() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 5_000 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 101
        });
        bytes memory signature = bytes("contract-sig");
        bytes32 digest = rfq.hashTypedDataV4(params);
        makerContract.program(digest, signature, false, false);

        vm.prank(alice);
        uint256 amountOut = rfq.verifyAndSwap(signature, params, bytes(""));
        assertGt(amountOut, 0, "amount out");
    }

    function test_invalidMagicReverts() public {
        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 1_000 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 102
        });
        bytes memory signature = bytes("bad-magic");
        bytes32 digest = rfq.hashTypedDataV4(params);
        makerContract.program(digest, signature, false, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuoteRFQ.Invalid1271MagicValue.selector, bytes4(0x00000000)));
        rfq.verifyAndSwap(signature, params, bytes(""));
    }

    function test_missing1271InterfaceReverts() public {
        No1271 no1271 = new No1271();
        vm.prank(rfq.owner());
        rfq.setMakerKey(address(no1271));

        IQuoteRFQ.QuoteParams memory params = IQuoteRFQ.QuoteParams({
            taker: alice,
            amountIn: 500 ether,
            minAmountOut: 0,
            isBaseIn: true,
            expiry: block.timestamp + 120,
            salt: 103
        });
        bytes memory signature = bytes("noop");

        vm.prank(alice);
        vm.expectRevert(QuoteRFQ.MakerMustBeEOA.selector);
        rfq.verifyAndSwap(signature, params, bytes(""));
    }
}
