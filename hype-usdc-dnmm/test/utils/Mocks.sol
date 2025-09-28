// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../contracts/interfaces/IERC20.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {IPyth} from "../../contracts/oracle/OracleAdapterPyth.sol";
import {MockERC20 as BaseMockERC20} from "../../contracts/mocks/MockERC20.sol";

interface IReentrancyHook {
    function onTokenTransfer(address token, address from, address to, uint256 amount) external;
}

contract MockHyperCorePx {
    struct Result {
        uint64 px;
        bool configured;
        bool success;
        bool shortReturn;
        bytes revertData;
    }

    mapping(uint32 => Result) internal results;

    function setResult(uint32 key, uint64 px) external {
        results[key] = Result({px: px, configured: true, success: true, shortReturn: false, revertData: ""});
    }

    function setShortResult(uint32 key, uint64 px) external {
        results[key] = Result({px: px, configured: true, success: true, shortReturn: true, revertData: ""});
    }

    function setFailure(uint32 key, bytes calldata revertData) external {
        results[key] = Result({px: 0, configured: true, success: false, shortReturn: false, revertData: revertData});
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (data.length != 32 && data.length != 4) revert("MockHyperCorePx:bad-len");
        uint32 key;
        assembly {
            key := shr(224, calldataload(0))
        }
        Result memory res = results[key];
        if (!res.configured) revert("MockHyperCorePx:missing");
        if (!res.success) {
            bytes memory revertData = res.revertData.length > 0 ? res.revertData : bytes("HC fail");
            assembly {
                revert(add(revertData, 0x20), mload(revertData))
            }
        }
        if (res.shortReturn) {
            return abi.encodePacked(uint32(res.px));
        }
        return abi.encode(res.px);
    }
}

contract MockHyperCoreBbo {
    struct Result {
        uint64 bid;
        uint64 ask;
        bool configured;
        bool success;
        bool shortReturn;
    }

    mapping(uint32 => Result) internal results;

    function setResult(uint32 key, uint64 bid_, uint64 ask_) external {
        results[key] = Result({bid: bid_, ask: ask_, configured: true, success: true, shortReturn: false});
    }

    function setShortResult(uint32 key, uint64 bid_) external {
        results[key] = Result({bid: bid_, ask: 0, configured: true, success: true, shortReturn: true});
    }

    function setFailure(uint32 key) external {
        results[key] = Result({bid: 0, ask: 0, configured: true, success: false, shortReturn: false});
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (data.length != 32 && data.length != 4) revert("MockHyperCoreBbo:bad-len");
        uint32 key;
        assembly {
            key := shr(224, calldataload(0))
        }
        Result memory res = results[key];
        if (!res.configured) revert("MockHyperCoreBbo:missing");
        if (!res.success) revert("MockHyperCoreBbo:fail");
        if (res.shortReturn) {
            return abi.encodePacked(res.bid);
        }
        return abi.encode(res.bid, res.ask);
    }
}

contract MockPyth is IPyth {
    mapping(bytes32 => Price) public feeds;

    function setPrice(bytes32 id, int64 price, int32 expo, uint64 conf, uint64 ts) external {
        feeds[id] = Price({price: price, conf: conf, expo: expo, publishTime: ts});
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {}

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        return feeds[id];
    }
}

contract ReentrantERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    address public hook;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error AllowanceExceeded(address owner, address spender, uint256 currentAllowance, uint256 neededAllowance);
    error BalanceTooLow(address account, uint256 balance, uint256 needed);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function setHook(address hook_) external {
        hook = hook_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < value) revert AllowanceExceeded(from, msg.sender, allowed, value);
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal virtual {
        uint256 balance = balanceOf[from];
        if (balance < value) revert BalanceTooLow(from, balance, value);
        balanceOf[from] = balance - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        if (hook != address(0) && to == hook) {
            IReentrancyHook(hook).onTokenTransfer(address(this), from, to, value);
        }
    }
}

contract MaliciousReceiver is IReentrancyHook {
    IDnmPool public pool;
    address public baseToken;
    address public quoteToken;
    bool public triggerReenter;
    bool public attackBaseIn;

    function configure(IDnmPool pool_, address baseToken_, address quoteToken_) external {
        pool = pool_;
        baseToken = baseToken_;
        quoteToken = quoteToken_;
    }

    function setTrigger(bool trigger) external {
        triggerReenter = trigger;
    }

    function setAttackSide(bool baseIn) external {
        attackBaseIn = baseIn;
    }

    function executeAttack(uint256 amountIn) external {
        IERC20 tokenIn = attackBaseIn ? IERC20(baseToken) : IERC20(quoteToken);
        tokenIn.approve(address(pool), amountIn);
        pool.swapExactIn(amountIn, 0, attackBaseIn, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
    }

    function onTokenTransfer(address, address, address, uint256) external override {
        if (!triggerReenter) return;
        triggerReenter = false;
        IERC20 tokenIn = attackBaseIn ? IERC20(baseToken) : IERC20(quoteToken);
        tokenIn.approve(address(pool), type(uint256).max);
        pool.swapExactIn(1, 0, attackBaseIn, IDnmPool.OracleMode.Spot, bytes(""), block.timestamp + 1);
    }
}

contract FeeOnTransferERC20 is BaseMockERC20 {
    uint16 public immutable feeBps;
    address public immutable feeRecipient;

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint16 feeBps_, address feeRecipient_)
        BaseMockERC20(name_, symbol_, decimals_, 0, msg.sender)
    {
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _transfer(address from, address to, uint256 value) internal virtual override {
        uint256 balance = balanceOf[from];
        if (balance < value) revert BalanceTooLow(from, balance, value);

        uint256 fee = feeBps == 0 ? 0 : (value * feeBps) / 10_000;
        uint256 net = value - fee;

        balanceOf[from] = balance - value;
        balanceOf[to] += net;
        emit Transfer(from, to, net);

        if (fee > 0) {
            balanceOf[feeRecipient] += fee;
            emit Transfer(from, feeRecipient, fee);
        }
    }
}

contract MockCurveDEX {
    IERC20 public base;
    IERC20 public quote;
    uint256 public baseReserves;
    uint256 public quoteReserves;

    constructor(address base_, address quote_) {
        base = IERC20(base_);
        quote = IERC20(quote_);
    }

    function seed(uint256 baseAmount, uint256 quoteAmount) external {
        require(base.transferFrom(msg.sender, address(this), baseAmount), "BASE_TRANSFER");
        require(quote.transferFrom(msg.sender, address(this), quoteAmount), "QUOTE_TRANSFER");
        baseReserves += baseAmount;
        quoteReserves += quoteAmount;
    }

    function quoteBaseIn(uint256 amountIn) public view returns (uint256 amountOut) {
        uint256 k = baseReserves * quoteReserves;
        uint256 newBase = baseReserves + amountIn;
        uint256 newQuote = k / newBase;
        amountOut = quoteReserves - newQuote;
    }

    function quoteQuoteIn(uint256 amountIn) public view returns (uint256 amountOut) {
        uint256 k = baseReserves * quoteReserves;
        uint256 newQuote = quoteReserves + amountIn;
        uint256 newBase = k / newQuote;
        amountOut = baseReserves - newBase;
    }

    function swapBaseIn(uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        require(base.transferFrom(msg.sender, address(this), amountIn), "BASE_IN");
        amountOut = quoteBaseIn(amountIn);
        require(amountOut >= minAmountOut, "SLIPPAGE");
        baseReserves += amountIn;
        quoteReserves -= amountOut;
        require(quote.transfer(recipient, amountOut), "QUOTE_OUT");
    }

    function swapQuoteIn(uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        require(quote.transferFrom(msg.sender, address(this), amountIn), "QUOTE_IN");
        amountOut = quoteQuoteIn(amountIn);
        require(amountOut >= minAmountOut, "SLIPPAGE");
        quoteReserves += amountIn;
        baseReserves -= amountOut;
        require(base.transfer(recipient, amountOut), "BASE_OUT");
    }
}

contract ArbBot {
    IDnmPool public pool;
    MockCurveDEX public dex;
    address public owner;

    constructor(IDnmPool pool_, MockCurveDEX dex_) {
        pool = pool_;
        dex = dex_;
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "BOT_OWNER");
        _;
    }

    function swapPool(
        uint256 amountIn,
        uint256 minOut,
        bool isBaseIn,
        IDnmPool.OracleMode mode,
        bytes calldata oracleData,
        uint256 deadline
    ) external onlyOwner returns (uint256 amountOut) {
        address baseToken = pool.baseTokenAddress();
        address quoteToken = pool.quoteTokenAddress();
        IERC20 tokenIn = isBaseIn ? IERC20(baseToken) : IERC20(quoteToken);
        IERC20 tokenOut = isBaseIn ? IERC20(quoteToken) : IERC20(baseToken);
        require(tokenIn.transferFrom(owner, address(this), amountIn), "POOL_TRANSFER_IN");
        tokenIn.approve(address(pool), amountIn);
        amountOut = pool.swapExactIn(amountIn, minOut, isBaseIn, mode, oracleData, deadline);
        uint256 bal = tokenOut.balanceOf(address(this));
        require(tokenOut.transfer(owner, bal), "POOL_TRANSFER_OUT");
    }

    function swapDex(uint256 amountIn, uint256 minOut, bool isBaseIn) external onlyOwner returns (uint256 amountOut) {
        address baseToken = pool.baseTokenAddress();
        address quoteToken = pool.quoteTokenAddress();
        IERC20 tokenIn = isBaseIn ? IERC20(baseToken) : IERC20(quoteToken);
        require(tokenIn.transferFrom(owner, address(this), amountIn), "DEX_TRANSFER_IN");
        tokenIn.approve(address(dex), amountIn);
        if (isBaseIn) {
            amountOut = dex.swapBaseIn(amountIn, minOut, owner);
        } else {
            amountOut = dex.swapQuoteIn(amountIn, minOut, owner);
        }
    }
}
