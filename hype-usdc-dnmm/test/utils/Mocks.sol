// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../contracts/interfaces/IERC20.sol";
import {IDnmPool} from "../../contracts/interfaces/IDnmPool.sol";
import {IPyth} from "../../contracts/oracle/OracleAdapterPyth.sol";

interface IReentrancyHook {
    function onTokenTransfer(address token, address from, address to, uint256 amount) external;
}

contract MockHyperCore {
    uint256 public bid;
    uint256 public ask;
    uint256 public mid;
    uint64 public spotTs;

    uint256 public emaMid;
    uint64 public emaTs;

    bytes4 internal constant SELECTOR_SPOT = 0x6a627842;
    bytes4 internal constant SELECTOR_ORDERBOOK = 0x3f5d0c52;
    bytes4 internal constant SELECTOR_EMA = 0x0e349d01;

    function setTOB(uint256 bid_, uint256 ask_, uint256 mid_, uint64 ts_) external {
        bid = bid_;
        ask = ask_;
        mid = mid_;
        spotTs = ts_;
    }

    function setEMA(uint256 emaMid_, uint64 emaTs_) external {
        emaMid = emaMid_;
        emaTs = emaTs_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        data;
        bytes4 selector;
        assembly {
            selector := calldataload(0)
        }
        if (selector == SELECTOR_SPOT) {
            return abi.encode(mid, spotTs);
        }
        if (selector == SELECTOR_ORDERBOOK) {
            return abi.encode(bid, ask);
        }
        if (selector == SELECTOR_EMA) {
            return abi.encode(emaMid, emaTs);
        }
        revert("HC_UNKNOWN");
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
    uint8 public decimals;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    address public hook;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

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
        require(allowed >= value, "ALLOWANCE");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "BALANCE");
        balanceOf[from] -= value;
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
        (address baseToken, address quoteToken,,,,) = pool.tokens();
        IERC20 tokenIn = isBaseIn ? IERC20(baseToken) : IERC20(quoteToken);
        IERC20 tokenOut = isBaseIn ? IERC20(quoteToken) : IERC20(baseToken);
        require(tokenIn.transferFrom(owner, address(this), amountIn), "POOL_TRANSFER_IN");
        tokenIn.approve(address(pool), amountIn);
        amountOut = pool.swapExactIn(amountIn, minOut, isBaseIn, mode, oracleData, deadline);
        uint256 bal = tokenOut.balanceOf(address(this));
        require(tokenOut.transfer(owner, bal), "POOL_TRANSFER_OUT");
    }

    function swapDex(uint256 amountIn, uint256 minOut, bool isBaseIn) external onlyOwner returns (uint256 amountOut) {
        (address baseToken, address quoteToken,,,,) = pool.tokens();
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
