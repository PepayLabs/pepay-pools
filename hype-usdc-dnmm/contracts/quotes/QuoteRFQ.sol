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

    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "Quote(address taker,uint256 amountIn,uint256 minAmountOut,bool isBaseIn,uint256 expiry,uint256 salt)"
    );

    IDnmPool public immutable pool;
    address public makerKey;
    address public owner;

    bytes32 private immutable _hashedName;
    bytes32 private immutable _hashedVersion;
    uint256 private immutable _domainChainId;
    bytes32 private immutable _domainSeparator;

    mapping(uint256 => bool) public consumedSalts;

    event MakerKeyUpdated(address indexed oldKey, address indexed newKey);
    event QuoteFilled(
        address indexed taker, bool isBaseIn, uint256 amountIn, uint256 amountOut, uint256 expiry, uint256 salt
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address pool_, address makerKey_) {
        require(pool_ != address(0), "POOL_ZERO");
        pool = IDnmPool(pool_);
        makerKey = makerKey_;
        owner = msg.sender;
        _hashedName = keccak256(bytes(NAME));
        _hashedVersion = keccak256(bytes(VERSION));
        _domainChainId = block.chainid;
        _domainSeparator = _buildDomainSeparator(_hashedName, _hashedVersion);
    }

    function verifyAndSwap(bytes calldata makerSignature, QuoteParams calldata params, bytes calldata oracleData)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        require(params.taker == msg.sender, "NOT_TAKER");
        require(block.timestamp <= params.expiry, "RFQ_EXPIRED");
        require(!consumedSalts[params.salt], "RFQ_USED");
        consumedSalts[params.salt] = true;

        bytes32 digest = hashQuote(params);
        require(_recoverSigner(digest, makerSignature) == makerKey, "BAD_SIG");

        (address baseToken, address quoteToken,,,,) = pool.tokens();
        address inputToken = params.isBaseIn ? baseToken : quoteToken;
        address outputToken = params.isBaseIn ? quoteToken : baseToken;

        inputToken.safeTransferFrom(params.taker, address(this), params.amountIn);

        uint256 inputBalanceBefore = IERC20(inputToken).balanceOf(address(this));
        uint256 outputBalanceBefore = IERC20(outputToken).balanceOf(address(this));

        inputToken.safeApprove(address(pool), params.amountIn);
        uint256 poolAmountOut = pool.swapExactIn(
            params.amountIn, params.minAmountOut, params.isBaseIn, IDnmPool.OracleMode.Spot, oracleData, params.expiry
        );
        inputToken.safeApprove(address(pool), 0);

        uint256 inputBalanceAfter = IERC20(inputToken).balanceOf(address(this));
        uint256 outputBalanceAfter = IERC20(outputToken).balanceOf(address(this));

        uint256 consumedInput = inputBalanceBefore - inputBalanceAfter;
        if (inputBalanceAfter > 0) {
            inputToken.safeTransfer(params.taker, inputBalanceAfter);
        }

        amountOut = outputBalanceAfter - outputBalanceBefore;
        require(amountOut >= poolAmountOut, "BAD_OUT");

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

    function hashQuote(QuoteParams calldata params) public view override returns (bytes32) {
        bytes32 structHash = keccak256(
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
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    function verifyQuoteSignature(address signer, QuoteParams calldata params, bytes calldata signature)
        external
        view
        override
        returns (bool)
    {
        return _recoverSigner(hashQuote(params), signature) == signer;
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (block.chainid == _domainChainId) {
            return _domainSeparator;
        }
        return _buildDomainSeparator(_hashedName, _hashedVersion);
    }

    function _buildDomainSeparator(bytes32 hashedName, bytes32 hashedVersion) private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, hashedName, hashedVersion, block.chainid, address(this))
        );
    }

    function _recoverSigner(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        require(signature.length == 65, "SIG_LEN");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "SIG_V");
        return ecrecover(digest, v, r, s);
    }
}
