// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IQuoteRFQ {
    struct QuoteParams {
        address taker;
        uint256 amountIn;
        uint256 minAmountOut;
        bool isBaseIn;
        uint256 expiry;
        uint256 salt;
    }

    function verifyAndSwap(bytes calldata makerSignature, QuoteParams calldata params, bytes calldata oracleData)
        external
        returns (uint256 amountOut);

    function setMakerKey(address newKey) external;
}
