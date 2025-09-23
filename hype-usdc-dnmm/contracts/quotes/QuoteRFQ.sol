// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuoteRFQ} from "../interfaces/IQuoteRFQ.sol";
import {IDnmPool} from "../interfaces/IDnmPool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../lib/SafeTransferLib.sol";
import {ReentrancyGuard} from "../lib/ReentrancyGuard.sol";

contract QuoteRFQ is IQuoteRFQ, ReentrancyGuard {
    using SafeTransferLib for address;

    string public constant NAME = "DNMM QuoteRFQ";
    string public constant VERSION = "1";

    error QuotePoolZero();
    error QuoteNotOwner();
    error QuoteNotTaker();
    error QuoteExpired();
    error QuoteAlreadyFilled();
    error QuoteSignerMismatch();
    error QuoteOutputBelowPool();
    error QuoteSignatureLength();
    error QuoteSignatureV();

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt)"
    );

    IDnmPool internal immutable POOL_;
    address public makerKey;
    address public owner;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    uint256 private immutable _DOMAIN_CHAIN_ID;
    bytes32 private immutable _DOMAIN_SEPARATOR;

    mapping(uint256 => bool) public consumedSalts;

    event MakerKeyUpdated(address indexed oldKey, address indexed newKey);
    event QuoteFilled(
        address indexed taker, bool isBaseIn, uint256 amountIn, uint256 amountOut, uint256 expiry, uint256 salt
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert QuoteNotOwner();
        _;
    }

    constructor(address pool_, address makerKey_) {
        if (pool_ == address(0)) revert QuotePoolZero();
        POOL_ = IDnmPool(pool_);
        makerKey = makerKey_;
        owner = msg.sender;
        _HASHED_NAME = keccak256(bytes(NAME));
        _HASHED_VERSION = keccak256(bytes(VERSION));
        _DOMAIN_CHAIN_ID = block.chainid;
        _DOMAIN_SEPARATOR = _buildDomainSeparator(_HASHED_NAME, _HASHED_VERSION);
    }

    function pool() public view returns (IDnmPool) {
        return POOL_;
    }

    function verifyAndSwap(bytes calldata makerSignature, QuoteParams calldata params, bytes calldata oracleData)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (params.taker != msg.sender) revert QuoteNotTaker();
        if (block.timestamp > params.expiry) revert QuoteExpired();
        if (consumedSalts[params.salt]) revert QuoteAlreadyFilled();
        consumedSalts[params.salt] = true;

        bytes32 digest = hashTypedDataV4(params);
        if (_recoverSigner(digest, makerSignature) != makerKey) revert QuoteSignerMismatch();

        (address baseToken, address quoteToken,,,,) = POOL_.tokens();
        address inputToken = params.isBaseIn ? baseToken : quoteToken;
        address outputToken = params.isBaseIn ? quoteToken : baseToken;

        inputToken.safeTransferFrom(params.taker, address(this), params.amountIn);

        uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(address(this));
        uint256 outputBalanceBefore = IERC20(outputToken).balanceOf(address(this));

        inputToken.safeApprove(address(POOL_), params.amountIn);
        uint256 poolAmountOut = POOL_.swapExactIn(
            params.amountIn, params.minAmountOut, params.isBaseIn, IDnmPool.OracleMode.Spot, oracleData, params.expiry
        );
        inputToken.safeApprove(address(POOL_), 0);

        uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(address(this));
        uint256 outputBalanceAfter = IERC20(outputToken).balanceOf(address(this));

        uint256 consumedInput = inputBalanceBefore - inputBalanceAfter;
        if (inputBalanceAfter > 0) {
            inputToken.safeTransfer(params.taker, inputBalanceAfter);
        }

        amountOut = outputBalanceAfter - outputBalanceBefore;
        if (amountOut < poolAmountOut) revert QuoteOutputBelowPool();

        outputToken.safeTransfer(params.taker, amountOut);

        emit QuoteFilled(params.taker, params.isBaseIn, consumedInput, amountOut, params.expiry, params.salt);
    }

    function setMakerKey(address newKey) external override onlyOwner {
        emit MakerKeyUpdated(makerKey, newKey);
        makerKey = newKey;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function hashQuote(QuoteParams calldata params) public pure override returns (bytes32) {
        return keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                params.taker,
                params.amountIn,
                params.minAmountOut,
                params.isBaseIn,
                params.expiry,
                params.salt
            )
        );
    }

    function hashTypedDataV4(QuoteParams calldata params) public view override returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), hashQuote(params)));
    }

    function verifyQuoteSignature(address signer, QuoteParams calldata params, bytes calldata signature)
        external
        view
        override
        returns (bool)
    {
        return _recoverSigner(hashTypedDataV4(params), signature) == signer;
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (block.chainid == _DOMAIN_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator(_HASHED_NAME, _HASHED_VERSION);
    }

    function _buildDomainSeparator(bytes32 hashedName, bytes32 hashedVersion) private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, hashedName, hashedVersion, block.chainid, address(this))
        );
    }

    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert QuoteSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert QuoteSignatureV();
        return ecrecover(digest, v, r, s);
    }
}
