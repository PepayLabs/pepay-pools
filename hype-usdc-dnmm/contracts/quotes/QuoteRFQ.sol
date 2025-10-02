// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IQuoteRFQ} from "../interfaces/IQuoteRFQ.sol";
import {IDnmPool} from "../interfaces/IDnmPool.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../lib/SafeTransferLib.sol";
import {ReentrancyGuard} from "../lib/ReentrancyGuard.sol";

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

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
    error QuoteOwnerZero();
    error QuoteInputMismatch();
    error QuoteMakerKeyZero();
    error MakerMustBeEOA(); // AUDIT:RFQ-001 require EOAs or compliant contracts
    error Invalid1271MagicValue(bytes4 provided); // AUDIT:RFQ-001 invalid 1271 magic

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt)"
    );
    bytes4 private constant ERC1271_MAGIC_VALUE = 0x1626ba7e;

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
        address indexed taker,
        bool isBaseIn,
        uint256 requestedAmountIn,
        uint256 amountOut,
        uint256 expiry,
        uint256 salt,
        uint256 actualAmountIn,
        uint256 actualAmountOut,
        uint256 leftoverReturned
    ); // AUDIT:RFQ-002 emit actual fill amounts
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert QuoteNotOwner();
        _;
    }

    constructor(address pool_, address makerKey_) {
        if (pool_ == address(0)) revert QuotePoolZero();
        if (makerKey_ == address(0)) revert QuoteMakerKeyZero();
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
        _assertValidMakerSignature(digest, makerSignature);

        address baseToken = POOL_.baseTokenAddress();
        address quoteToken = POOL_.quoteTokenAddress();
        address inputToken = params.isBaseIn ? baseToken : quoteToken;
        address outputToken = params.isBaseIn ? quoteToken : baseToken;

        uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(address(this));
        uint256 outputBalanceBefore = IERC20(outputToken).balanceOf(address(this));

        inputToken.safeTransferFrom(msg.sender, address(this), params.amountIn);
        uint256 inputReceived = IERC20(inputToken).balanceOf(address(this)) - inputBalanceBefore;
        if (inputReceived != params.amountIn) revert QuoteInputMismatch();

        inputToken.safeApprove(address(POOL_), params.amountIn);
        uint256 poolAmountOut = POOL_.swapExactIn(
            params.amountIn, params.minAmountOut, params.isBaseIn, IDnmPool.OracleMode.Spot, oracleData, params.expiry
        );
        inputToken.safeApprove(address(POOL_), 0);

        uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(address(this));
        uint256 outputBalanceAfter = IERC20(outputToken).balanceOf(address(this));

        uint256 leftoverIn = inputBalanceAfter;
        if (leftoverIn > 0) {
            inputToken.safeTransfer(params.taker, leftoverIn);
        }

        amountOut = outputBalanceAfter - outputBalanceBefore;
        if (amountOut < poolAmountOut) revert QuoteOutputBelowPool();

        outputToken.safeTransfer(params.taker, amountOut);

        uint256 actualAmountIn = inputReceived - leftoverIn; // AUDIT:RFQ-002 track filled input after partial return
        emit QuoteFilled(
            params.taker,
            params.isBaseIn,
            params.amountIn,
            amountOut,
            params.expiry,
            params.salt,
            actualAmountIn,
            amountOut,
            leftoverIn
        );
    }

    function setMakerKey(address newKey) external override onlyOwner {
        if (newKey == address(0)) revert QuoteMakerKeyZero();
        emit MakerKeyUpdated(makerKey, newKey);
        makerKey = newKey;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert QuoteOwnerZero();
        emit OwnershipTransferred(owner, newOwner);
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
        bytes32 digest = hashTypedDataV4(params);
        if (signer.code.length == 0) {
            if (signature.length != 65) return false;
            return _recoverSigner(digest, signature) == signer;
        }
        (bool ok, bytes memory data) =
            signer.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature));
        if (!ok || data.length < 32) return false;
        return bytes4(data) == ERC1271_MAGIC_VALUE;
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (block.chainid == _DOMAIN_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator(_HASHED_NAME, _HASHED_VERSION);
    }

    function _buildDomainSeparator(bytes32 hashedName, bytes32 hashedVersion) private view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, hashedName, hashedVersion, block.chainid, address(this)));
    }

    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert QuoteSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert QuoteSignatureV();
        return ecrecover(digest, v, r, s);
    }

    function _assertValidMakerSignature(bytes32 digest, bytes calldata signature) internal view {
        address key = makerKey;
        if (key.code.length == 0) {
            if (_recoverSigner(digest, signature) != key) revert QuoteSignerMismatch();
            return;
        }

        (bool ok, bytes memory data) =
            key.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature));
        if (!ok || data.length < 32) revert MakerMustBeEOA(); // AUDIT:RFQ-001 reject contracts without 1271 support

        bytes4 magic = bytes4(data);
        if (magic != ERC1271_MAGIC_VALUE) revert Invalid1271MagicValue(magic);
    }
}
