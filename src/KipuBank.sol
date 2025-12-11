// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Uniswap / Permit2
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";

import {IPermit2} from "https://raw.githubusercontent.com/Uniswap/permit2/main/src/interfaces/IPermit2.sol";

/// @title KipuBank - Multi-asset vault with Uniswap V4, always consolidating in USDC
contract KipuBank is ERC20, AccessControl {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Chainlink ETH/USD
    AggregatorV3Interface public immutable priceFeed;

    // USDC
    uint8 public constant USDC_DECIMALS = 6;
    address public immutable usdc;

    /// @notice Global bank cap in USDC (6 decimals)
    uint256 public immutable bankCapUsd;

    /// @notice Per-user cap in USDC (6 decimals)
    uint256 public immutable userCapUsd;

    /// @notice Withdrawal limit (USDC, 6 decimals)
    uint256 public immutable withdrawLimitUsd;

    // Uniswap / Permit2
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;
    IPoolManager public immutable poolManager;

    // Total USDC in the bank (sum of all users)
    uint256 public totalBankBalanceUsdc;

    // Global slippage for swaps (e.g., 9500 = 95%)
    uint256 public minAmountOutBps = 9500;

    // Stats / funds
    struct Total {
        uint256 depositsAmountUsd; // always use USDC-decimals
        uint256 depositsQtt;
        uint256 withdrawsQtt;
    }

    // user => token => stats (kept for compatibility, but main logical token is usdc)
    mapping(address => mapping(address => Total)) public totals;

    // user => token => raw balance (for USDC, mirrors usdcBalances)
    mapping(address => mapping(address => uint256)) public funds;

    // Consolidated USDC balance of each user
    mapping(address => uint256) public usdcBalances;

    bool private locked;

    // Events
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 amountUsd);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 amountUsd);
    event ArbitraryTokenDeposited(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcReceived
    );
    event SwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event SlippageToleranceUpdated(uint256 oldBps, uint256 newBps);

    // Errors
    error ReentrancyDetected();
    error ZeroAmount();
    error AboveLimit();
    error NoFund();
    error PriceFeedError();
    error BankCapExceeded();
    error SwapFailed();
    error InvalidSlippage();
    error InsufficientOutput();
    error InvalidToken();

    // Modifiers
    modifier noReentrancy() {
        if (locked) revert ReentrancyDetected();
        locked = true;
        _;
        locked = false;
    }

    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "ADMIN only");
        _;
    }

    /// @param _withdrawLimitUsd Max per withdrawal (USDC)
    /// @param _userCapUsd Per-user cap (USDC)
    /// @param _bankCapUsd Global cap (USDC)
    constructor(
        uint256 _withdrawLimitUsd,
        uint256 _userCapUsd,
        uint256 _bankCapUsd,
        address _priceFeed,
        address _usdc,
        address _universalRouter,
        address _permit2,
        address _poolManager
    ) ERC20("MyToken", "MTK") {
        require(_withdrawLimitUsd > 0, "withdraw limit required");
        require(_userCapUsd > 0 && _bankCapUsd > 0, "caps required");
        require(_withdrawLimitUsd <= _userCapUsd, "Withdraw > user cap");
        require(_userCapUsd <= _bankCapUsd, "User cap > bank cap");
        require(_usdc != address(0), "Invalid USDC");
        require(_universalRouter != address(0), "Invalid router");
        require(_permit2 != address(0), "Invalid permit2");
        require(_poolManager != address(0), "Invalid poolManager");

        priceFeed = AggregatorV3Interface(_priceFeed);
        usdc = _usdc;
        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2(_permit2);
        poolManager = IPoolManager(_poolManager);

        withdrawLimitUsd = _withdrawLimitUsd;
        userCapUsd = _userCapUsd;
        bankCapUsd = _bankCapUsd;

        _mint(msg.sender, 1000 * 10 ** uint256(decimals()));
        _grantRole(ADMIN_ROLE, msg.sender);

        // Approve Permit2 for USDC (useful for possible future reverse swaps)
        IERC20(_usdc).approve(_permit2, type(uint256).max);
    }

    // ================== ORACLE (for metrics only) ==================

    function getEthUsdPrice() public view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        if (price <= 0) revert PriceFeedError();
        return uint256(price);
    }

    /// @notice Metrics-only utility; cap logic uses real USDC exclusively
    function tokenToUsd(address token, uint256 amount) public view returns (uint256) {
        uint8 decs = token == address(0) ? 18 : IERC20Metadata(token).decimals();

        if (token == address(0)) {
            uint256 price = getEthUsdPrice(); // 8 decimals
            return (amount * price * (10 ** USDC_DECIMALS)) / (1e18 * 1e8);
        } else if (token == usdc) {
            return amount;
        } else {
            // Only an estimate; not used for cap
            uint256 price = 1e8;
            uint256 normalized = amount * (10 ** USDC_DECIMALS) / (10 ** decs);
            return (normalized * price) / 1e8;
        }
    }

    // ================== SLIPPAGE ==================

    function setSlippageTolerance(uint256 _minAmountOutBps) external onlyAdmin {
        if (_minAmountOutBps > 10000 || _minAmountOutBps < 5000) revert InvalidSlippage();
        emit SlippageToleranceUpdated(minAmountOutBps, _minAmountOutBps);
        minAmountOutBps = _minAmountOutBps;
    }

    // ================== DIRECT USDC DEPOSIT ==================

    /// @notice Only accepts USDC; any other token must use `depositArbitraryToken`
    function deposit(address token, uint256 amount) external noReentrancy {
        if (amount == 0) revert ZeroAmount();
        if (token != usdc) revert InvalidToken();

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);

        // Caps: per user and global
        uint256 newUserBalance = usdcBalances[msg.sender] + amount;
        if (newUserBalance > userCapUsd) revert AboveLimit();
        if (totalBankBalanceUsdc + amount > bankCapUsd) revert BankCapExceeded();

        usdcBalances[msg.sender] = newUserBalance;
        totalBankBalanceUsdc += amount;

        // Logical stats via USDC
        _updateTotals(msg.sender, usdc, amount, true);
        funds[msg.sender][usdc] += amount;

        emit Deposited(msg.sender, usdc, amount, amount);
    }

    // ================== DEPOSITS WITH SWAP TO USDC ==================

    /// @notice Deposit arbitrary ERC-20, swap→USDC, credit USDC balance
    function depositArbitraryToken(
        address tokenIn,
        uint256 amountIn,
        uint256 quotedUsdc,   // expected value (from off-chain quoter)
        uint24 poolFee,
        int24 tickSpacing
    ) external noReentrancy {
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == address(0) || tokenIn == usdc) revert InvalidToken();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // minOut = quotedUsdc * minAmountOutBps / 10000
        uint256 minAmountOut = (quotedUsdc * minAmountOutBps) / 10000;

        uint256 usdcReceived = _swapExactInputSingle(
            tokenIn,
            usdc,
            amountIn,
            minAmountOut,
            poolFee,
            tickSpacing
        );

        if (usdcReceived < minAmountOut) revert InsufficientOutput();

        // Caps
        uint256 newUserBalance = usdcBalances[msg.sender] + usdcReceived;
        if (newUserBalance > userCapUsd) revert AboveLimit();
        if (totalBankBalanceUsdc + usdcReceived > bankCapUsd) revert BankCapExceeded();

        usdcBalances[msg.sender] = newUserBalance;
        totalBankBalanceUsdc += usdcReceived;

        _updateTotals(msg.sender, usdc, usdcReceived, true);
        funds[msg.sender][usdc] += usdcReceived;

        emit ArbitraryTokenDeposited(msg.sender, tokenIn, amountIn, usdcReceived);
        emit Deposited(msg.sender, usdc, usdcReceived, usdcReceived);
    }

    /// @notice Deposit ETH, swap→USDC, credit USDC balance
    function depositEthForUsdc(
        uint256 quotedUsdc,
        uint24 poolFee,
        int24 tickSpacing
    ) external payable noReentrancy {
        if (msg.value == 0) revert ZeroAmount();

        uint256 minAmountOut = (quotedUsdc * minAmountOutBps) / 10000;

        uint256 usdcReceived = _swapExactInputSingle(
            address(0),  // native ETH
            usdc,
            msg.value,
            minAmountOut,
            poolFee,
            tickSpacing
        );

        if (usdcReceived < minAmountOut) revert InsufficientOutput();

        uint256 newUserBalance = usdcBalances[msg.sender] + usdcReceived;
        if (newUserBalance > userCapUsd) revert AboveLimit();
        if (totalBankBalanceUsdc + usdcReceived > bankCapUsd) revert BankCapExceeded();

        usdcBalances[msg.sender] = newUserBalance;
        totalBankBalanceUsdc += usdcReceived;

        _updateTotals(msg.sender, usdc, usdcReceived, true);
        funds[msg.sender][usdc] += usdcReceived;

        emit ArbitraryTokenDeposited(msg.sender, address(0), msg.value, usdcReceived);
        emit Deposited(msg.sender, usdc, usdcReceived, usdcReceived);
    }

    // ================== INTERNAL SWAPS (UNISWAP V4 + UNIVERSAL ROUTER) ==================

    /// @notice Unified internal swap - uses address(0) for native ETH
    function _swapExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint24 poolFee,
        int24 tickSpacing
    ) internal returns (uint256 amountOut) {
        bool isNativeIn = (tokenIn == address(0));
        
        // Approve tokens ERC20 via Permit2
        if (!isNativeIn) {
            IERC20(tokenIn).approve(address(permit2), amountIn);
            permit2.approve(
                tokenIn,
                address(universalRouter),
                uint160(amountIn),
                uint48(block.timestamp + 3600)
            );
        }

        // Determines currencies and swap direction
        bool zeroForOne = tokenIn < tokenOut;
        
        PoolKey memory poolKey = PoolKey({
            currency0: zeroForOne ? Currency.wrap(tokenIn) : Currency.wrap(tokenOut),
            currency1: zeroForOne ? Currency.wrap(tokenOut) : Currency.wrap(tokenIn),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // Prepare swap command
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            poolKey,
            zeroForOne,
            int256(amountIn),
            uint160(zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            bytes("")
        );
        params[1] = abi.encode(Currency.wrap(tokenIn), amountIn);
        params[2] = abi.encode(Currency.wrap(tokenOut), minAmountOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(
                uint8(Actions.SWAP_EXACT_IN_SINGLE),
                uint8(Actions.SETTLE_ALL),
                uint8(Actions.TAKE_ALL)
            ),
            params
        );

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Execute swap (with or without ETH)
        if (isNativeIn) {
            universalRouter.execute{value: amountIn}(
                abi.encodePacked(uint8(Commands.V4_SWAP)),
                inputs,
                block.timestamp + 3600
            );
        } else {
            universalRouter.execute(
                abi.encodePacked(uint8(Commands.V4_SWAP)),
                inputs,
                block.timestamp + 3600
            );
        }

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
        emit SwapExecuted(tokenIn, tokenOut, amountIn, amountOut);
    }


    // ================== WITHDRAWALS ==================

    /// @notice Generic withdrawal; in practice, use withdrawUsdc (the bank's logical token)
    function withdraw(address token, uint256 amount) external noReentrancy {
        if (funds[msg.sender][token] == 0) revert NoFund();
        if (amount == 0 || amount > funds[msg.sender][token]) revert AboveLimit();

        if (token == usdc && amount > withdrawLimitUsd) revert AboveLimit();

        funds[msg.sender][token] -= amount;
        _updateTotals(msg.sender, token, token == usdc ? amount : tokenToUsd(token, amount), false);

        if (token == usdc) {
            usdcBalances[msg.sender] -= amount;
            totalBankBalanceUsdc -= amount;
        }

        if (token == address(0)) {
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Withdrawn(msg.sender, token, amount, token == usdc ? amount : tokenToUsd(token, amount));
    }

    function withdrawUsdc(uint256 amount) external noReentrancy {
        if (amount == 0) revert ZeroAmount();
        if (usdcBalances[msg.sender] == 0) revert NoFund();
        if (amount > usdcBalances[msg.sender]) revert AboveLimit();
        if (amount > withdrawLimitUsd) revert AboveLimit();

        usdcBalances[msg.sender] -= amount;
        funds[msg.sender][usdc] -= amount;
        totalBankBalanceUsdc -= amount;

        _updateTotals(msg.sender, usdc, amount, false);

        IERC20(usdc).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, usdc, amount, amount);
    }

    // ================== VIEWS ==================

    function getUserUsdcBalance(address user) external view returns (uint256) {
        return usdcBalances[user];
    }

    function getTotalBankBalance() external view returns (uint256) {
        return totalBankBalanceUsdc;
    }

    function getRemainingCapacityGlobal() external view returns (uint256) {
        if (totalBankBalanceUsdc >= bankCapUsd) return 0;
        return bankCapUsd - totalBankBalanceUsdc;
    }

    function getRemainingCapacityUser(address user) external view returns (uint256) {
        if (usdcBalances[user] >= userCapUsd) return 0;
        return userCapUsd - usdcBalances[user];
    }

    function getUserTokenStats(address user, address token)
        external
        view
        returns (
            uint256 depositsAmountUsd,
            uint256 depositsQtt,
            uint256 withdrawsQtt,
            uint256 currentBalance
        )
    {
        Total memory t = totals[user][token];
        return (t.depositsAmountUsd, t.depositsQtt, t.withdrawsQtt, funds[user][token]);
    }

    // ================== INTERNAL / ADMIN ==================

    function _updateTotals(address user, address token, uint256 amountUsd, bool isDeposit) private {
        if (isDeposit) {
            totals[user][token].depositsAmountUsd += amountUsd;
            totals[user][token].depositsQtt += 1;
        } else {
            totals[user][token].withdrawsQtt += 1;
        }
    }

    function adminWithdraw(address token, uint256 amount, address to) external onlyAdmin {
        if (token == usdc && amount <= totalBankBalanceUsdc) {
            totalBankBalanceUsdc -= amount;
        }
        IERC20(token).safeTransfer(to, amount);
    }

    function approveTokenForPermit2(address token) external onlyAdmin {
        IERC20(token).approve(address(permit2), type(uint256).max);
    }

    // Disables receive/fallback as a deposit method, to force swap→USDC
    receive() external payable {
        revert("Direct ETH not accepted");
    }

    fallback() external payable {
        if (msg.value > 0) {
            revert("Direct ETH not accepted");
        }
    }
}