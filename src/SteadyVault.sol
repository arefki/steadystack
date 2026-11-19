// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { PriceMath } from "./PriceMath.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniswapV3PoolMinimal {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @title SteadyVault — DCA vault for SteadyStack (Reactive Omni Buildathon).
/// @notice Lives on Base Sepolia. Receives callbacks from SteadyReactive (Lasna)
/// and executes USDC -> WETH swaps DIRECTLY against the Uniswap V3 pool
/// (pool.swap + uniswapV3SwapCallback). No router is used: the address the plan
/// recorded as "SwapRouter02" (0x94cC0AaC...) turned out to be the
/// NonfungiblePositionManager (verified on-chain 2026-11-19: it has mint() +
/// factory() + WETH9() but no exactInputSingle), and the canonical SwapRouter02
/// (0x68b346...) + Universal Router have no code on Base Sepolia. Calling the
/// pool directly is simpler, cheaper, and removes the router dependency.
/// Design decisions (see helper-fanout-design-review-phase3.md):
/// - minOut is derived VAULT-SIDE at execution time from the live pool price
///   (slot0 + 2% slippage band), never in the reactive contract (H2 fix).
///   QuoterV2 was rejected: it can revert inside a callback (thin testnet
///   liquidity) and a reverting callback is charged in full as CallbackFailure.
/// - executeBuy RE-CHECKS the live price vs maxPrice at execution time (H4 fix:
///   the price can move between the Lasna tick and the callback).
/// - Expected skips (paused, price too high, low balance, no price) EMIT
///   BuySkipped and RETURN instead of reverting (D6): a reverting callback
///   leaves debt that stalls the whole loop. Only genuine errors (e.g. a pool
///   revert, or output below minOut) propagate.
/// - No token approvals at all: the vault pays the pool in the swap callback
///   with a plain transfer from its own balance.
contract SteadyVault is AbstractCallback {
    // Base Sepolia canonical addresses (verified on-chain 2026-11-19).
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant POOL = 0x46880b404CD35c165EDdefF7421019F8dD25F4Ad;
    uint256 internal constant SLIPPAGE_BPS = 200; // 2% slippage band on minOut
    // Uniswap V3 MIN_SQRT_RATIO + 1, used as the (effectively unlimited) price
    // limit for zeroForOne swaps. NOTE: this pool REJECTS sqrtPriceLimitX96 = 0
    // with 'SPL' (verified in the fork test 2026-11-19) — unlike canonical V3,
    // 0 is not accepted as "no limit" here, so pass the explicit floor instead.
    uint160 internal constant SQRT_LIMIT_ZERO_FOR_ONE = 4295128740;

    uint8 internal constant SKIP_PAUSED = 1;
    uint8 internal constant SKIP_PRICE_HIGH = 2;
    uint8 internal constant SKIP_LOW_BALANCE = 3;
    uint8 internal constant SKIP_NO_PRICE = 4;

    address public immutable owner;
    bool public paused;
    uint256 public buyCount;
    uint256 public totalUsdcSpent;
    uint256 public totalWethBought;

    event Bought(address indexed reactive, uint256 amountIn, uint256 amountOut, uint256 price, uint256 blockNumber);
    event BuySkipped(address indexed reactive, uint8 reason, uint256 price, uint256 maxPrice);
    event PausedSet(address indexed reactive, bool paused);
    event OwnerResumed();

    error NotOwner();
    error NotPool();
    error AmountTooLarge(uint256 amountIn);
    error SlippageExceeded(uint256 amountOut, uint256 minOut);
    // TransferFailed is inherited from AbstractPayer.
    error UnexpectedSwapAmounts(int256 amount0, int256 amount1);

    constructor(IPayable callbackProxy_, address callbackSender_) AbstractCallback(callbackProxy_, callbackSender_) {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Executes one DCA buy. Called only by the callback proxy on behalf
    /// of the paired reactive contract. Skips (with an event) instead of
    /// reverting on expected guard conditions.
    function executeBuy(address reactive_, uint256 amountIn_, uint256 maxPrice_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        // F3 (code review 2026-11-19, nesa): explicit bound for the int256 cast
        // below — a clear error beats a checked-cast panic if the rule's
        // amountIn ever drifts toward the boundary. type(int256).max is
        // positive, so the uint256 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (amountIn_ > uint256(type(int256).max)) revert AmountTooLarge(amountIn_);
        // Only sqrtPriceX96 is needed from slot0; the rest is intentionally ignored.
        // forge-lint: disable-next-line(unused-return)
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(POOL).slot0();
        uint256 price = PriceMath.priceFromSqrt(sqrtPriceX96);

        if (paused) {
            emit BuySkipped(reactive_, SKIP_PAUSED, price, maxPrice_);
            return;
        }
        if (price == 0) {
            emit BuySkipped(reactive_, SKIP_NO_PRICE, 0, maxPrice_);
            return;
        }
        if (price > maxPrice_) {
            emit BuySkipped(reactive_, SKIP_PRICE_HIGH, price, maxPrice_);
            return;
        }
        if (IERC20Minimal(USDC).balanceOf(address(this)) < amountIn_) {
            emit BuySkipped(reactive_, SKIP_LOW_BALANCE, price, maxPrice_);
            return;
        }

        // Spot-derived output estimate: WETH(18 dec) = USDC(6 dec) * 1e18 / price6.
        uint256 amountOutEst = (amountIn_ * 1e18) / price;
        // Rounding from the floored estimate above is at most 1 wei of WETH.
        // forge-lint: disable-next-line(divide-before-multiply)
        uint256 minOut = (amountOutEst * (10000 - SLIPPAGE_BPS)) / 10000;

        // Direct pool swap: token0 (USDC) -> token1 (WETH), exact input.
        // The pool pays WETH to this contract and calls back for the USDC.
        // amountIn_ is a USDC amount (bounded by the vault balance, far below
        // int256.max); the 0.8 checked cast reverts on overflow regardless.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountInSigned = int256(amountIn_);
        (int256 amount0, int256 amount1) = IUniswapV3PoolMinimal(POOL).swap(
            address(this), true, amountInSigned, SQRT_LIMIT_ZERO_FOR_ONE, ""
        );
        // Exact-input invariant: the pool must bill exactly amountIn_ of USDC,
        // and must pay out WETH (amount1 negative). Anything else is a bug.
        if (amount0 != amountInSigned || amount1 >= 0) revert UnexpectedSwapAmounts(amount0, amount1);
        // amount1 < 0 is established by the check above, so -amount1 > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountOut = uint256(-amount1);
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);

        buyCount++;
        totalUsdcSpent += amountIn_;
        totalWethBought += amountOut;
        // The pool cannot reenter executeBuy (onlyServiceProvider), and the
        // swap callback only transfers tokens, so this emit cannot be reordered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Bought(reactive_, amountIn_, amountOut, price, block.number);
    }

    /// @notice Uniswap V3 swap callback: pays the pool the input tokens.
    /// Only the pool may call it. For our USDC -> WETH swaps only amount0Delta
    /// is positive; the amount1Delta branch is kept for completeness.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != POOL) revert NotPool();
        // Deltas are positive here by the guards below; the 0.8 checked casts
        // revert on overflow regardless.
        if (amount0Delta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (!IERC20Minimal(USDC).transfer(POOL, uint256(amount0Delta))) revert TransferFailed();
        }
        if (amount1Delta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (!IERC20Minimal(WETH).transfer(POOL, uint256(amount1Delta))) revert TransferFailed();
        }
    }

    /// @notice Pauses/unpauses buys. Called only by the callback proxy on behalf
    /// of the paired reactive contract (guard trips/clears).
    function setPaused(address reactive_, bool paused_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        paused = paused_;
        emit PausedSet(reactive_, paused_);
    }

    /// @notice Owner break-glass (F2, code review 2026-11-19): unpauses the
    /// vault directly if the reactive's setPaused(false) callback was lost
    /// (cross-chain drop). The reactive re-pauses on the next guard trip.
    function resumeGuard() external onlyOwner {
        paused = false;
        emit OwnerResumed();
    }

    /// @notice Owner-only demo fund management.
    function withdrawUSDC(uint256 amount_) external onlyOwner {
        if (!IERC20Minimal(USDC).transfer(owner, amount_)) revert TransferFailed();
    }

    /// @notice Owner-only demo fund management.
    function withdrawWETH(uint256 amount_) external onlyOwner {
        if (!IERC20Minimal(WETH).transfer(owner, amount_)) revert TransferFailed();
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Outstanding debt to the callback proxy (H3 runbook helper).
    function debt() external view returns (uint256) {
        return _SERVICE_PROVIDER.debt(address(this));
    }
}
