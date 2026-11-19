// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { SteadyVault } from "../src/SteadyVault.sol";

/// @notice Minimal ERC20 mock etched at the USDC address.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public lastApproveSpender;
    uint256 public lastApproveAmount;

    function setBalance(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        lastApproveSpender = spender;
        lastApproveAmount = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Minimal Uniswap V3 pool mock etched at the pool address.
/// swap() behaves like the real pool: it invokes the caller's
/// uniswapV3SwapCallback with the owed/received deltas, then returns them.
contract MockPool {
    uint160 public sqrtPriceX96;
    uint256 public amountOutToReturn;
    bool public shouldRevert;

    address public lastSwapRecipient;
    bool public lastSwapZeroForOne;
    int256 public lastSwapAmount;
    uint160 public lastSwapLimit;
    uint256 public swapCount;

    function setSqrtPrice(uint160 v) external {
        sqrtPriceX96 = v;
    }

    function setAmountOut(uint256 v) external {
        amountOutToReturn = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(!shouldRevert, "pool revert");
        lastSwapRecipient = recipient;
        lastSwapZeroForOne = zeroForOne;
        lastSwapAmount = amountSpecified;
        lastSwapLimit = sqrtPriceLimitX96;
        swapCount++;
        // Exact-input USDC -> WETH: caller owes amountSpecified USDC (amount0
        // delta positive) and receives amountOutToReturn WETH (amount1 negative).
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
            amountSpecified, -int256(amountOutToReturn), data
        );
        return (amountSpecified, -int256(amountOutToReturn));
    }
}

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Minimal callback-proxy mock etched at the proxy address.
contract MockProxy {
    uint256 public debtValue;

    receive() external payable {}

    function setDebt(uint256 v) external {
        debtValue = v;
    }

    function debt(address) external view returns (uint256) {
        return debtValue;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }
}

contract SteadyVaultTest is Test {
    address internal constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant POOL = 0x46880b404CD35c165EDdefF7421019F8dD25F4Ad;
    address internal constant REACTIVE = 0x00000000000000000000000000000000DeaDBeef;

    uint160 internal constant SQRT_3000 = 1446501726624926496477173928747178; // price 2,999,999,999
    uint160 internal constant SQRT_3300 = 1379185281616022357605400610384815; // price 3,299,999,999
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342; // price 0

    uint256 internal constant AMOUNT_IN = 1_000_000; // 1 USDC
    uint256 internal constant MAX_PRICE = 30_000_000_000; // $30,000
    // amountOut estimate at $3,000: 1e6 * 1e18 / 2999999999 = 333333333444444;
    // minOut at 2% slippage: 326666666775555.
    uint256 internal constant EXPECTED_MIN_OUT = 326666666775555;

    SteadyVault internal vault;

    event Bought(address indexed reactive, uint256 amountIn, uint256 amountOut, uint256 price, uint256 blockNumber);
    event BuySkipped(address indexed reactive, uint8 reason, uint256 price, uint256 maxPrice);
    event PausedSet(address indexed reactive, bool paused);
    event OwnerResumed();

    function setUp() public {
        vm.etch(USDC, address(new MockERC20()).code);
        vm.etch(WETH, address(new MockERC20()).code);
        vm.etch(POOL, address(new MockPool()).code);
        vm.etch(PROXY, address(new MockProxy()).code);
        vault = new SteadyVault(IPayable(payable(PROXY)), REACTIVE);
        MockPool(POOL).setSqrtPrice(SQRT_3000);
        MockERC20(USDC).setBalance(address(vault), 10_000_000); // 10 USDC
        MockPool(POOL).setAmountOut(333333333444444);
    }

    function _executeBuy() internal {
        vm.prank(PROXY);
        vault.executeBuy(REACTIVE, AMOUNT_IN, MAX_PRICE);
    }

    function _setPaused(bool p) internal {
        vm.prank(PROXY);
        vault.setPaused(REACTIVE, p);
    }

    // ---- access control ----

    function test_ExecuteBuyRevertsFromNonProxy() public {
        vm.expectRevert();
        vault.executeBuy(REACTIVE, AMOUNT_IN, MAX_PRICE);
    }

    function test_ExecuteBuyRevertsFromWrongSender() public {
        vm.prank(PROXY);
        vm.expectRevert();
        vault.executeBuy(address(0x1234), AMOUNT_IN, MAX_PRICE);
    }

    function test_SetPausedRevertsFromNonProxy() public {
        vm.expectRevert();
        vault.setPaused(REACTIVE, true);
    }

    function test_SetPausedRevertsFromWrongSender() public {
        vm.prank(PROXY);
        vm.expectRevert();
        vault.setPaused(address(0x1234), true);
    }

    // ---- happy path ----

    function test_ExecuteBuySwapsWhenPriceOk() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit Bought(REACTIVE, AMOUNT_IN, 333333333444444, 2999999999, block.number);
        _executeBuy();

        assertEq(vault.buyCount(), 1);
        assertEq(vault.totalUsdcSpent(), AMOUNT_IN);
        assertEq(vault.totalWethBought(), 333333333444444);
        assertEq(MockPool(POOL).swapCount(), 1);
        assertEq(MockPool(POOL).lastSwapRecipient(), address(vault));
        assertTrue(MockPool(POOL).lastSwapZeroForOne()); // token0 USDC -> token1 WETH
        assertEq(MockPool(POOL).lastSwapAmount(), int256(AMOUNT_IN));
        assertEq(MockPool(POOL).lastSwapLimit(), 4295128740); // MIN_SQRT_RATIO + 1 (pool rejects 0)
        // The vault paid the pool 1 USDC in the swap callback.
        assertEq(MockERC20(USDC).balanceOf(address(vault)), 9_000_000);
        assertEq(MockERC20(USDC).balanceOf(POOL), 1_000_000);
    }

    function test_PoolSwapRevertPropagates() public {
        MockPool(POOL).setShouldRevert(true);
        vm.prank(PROXY);
        vm.expectRevert("pool revert");
        vault.executeBuy(REACTIVE, AMOUNT_IN, MAX_PRICE);
        assertEq(vault.buyCount(), 0);
    }

    function test_SlippageBelowMinOutReverts() public {
        // Pool returns 1 wei less than minOut -> the whole buy reverts
        // (atomic with the swap, so no partial fill).
        MockPool(POOL).setAmountOut(EXPECTED_MIN_OUT - 1);
        vm.prank(PROXY);
        vm.expectRevert();
        vault.executeBuy(REACTIVE, AMOUNT_IN, MAX_PRICE);
        assertEq(vault.buyCount(), 0);
        assertEq(MockERC20(USDC).balanceOf(address(vault)), 10_000_000);
    }

    function test_SwapAtExactMinOutExecutes() public {
        MockPool(POOL).setAmountOut(EXPECTED_MIN_OUT);
        _executeBuy();
        assertEq(vault.buyCount(), 1);
    }

    function test_SwapCallbackRejectsNonPool() public {
        vm.expectRevert();
        vault.uniswapV3SwapCallback(1_000_000, -333333333444444, "");
    }

    /// @notice F3 (nesa, code review 2026-11-19): an amountIn above int256.max
    /// must revert with an explicit error, not a silent checked-cast panic.
    function test_ExecuteBuyRejectsHugeAmount() public {
        uint256 huge = uint256(type(int256).max) + 1;
        vm.prank(PROXY);
        vm.expectRevert(abi.encodeWithSelector(SteadyVault.AmountTooLarge.selector, huge));
        vault.executeBuy(REACTIVE, huge, MAX_PRICE);
        assertEq(vault.buyCount(), 0);
    }

    // ---- skip paths (return + event, never revert: design review D6) ----

    function test_ExecuteBuySkipsWhenPaused() public {
        _setPaused(true);
        assertTrue(vault.paused());

        vm.expectEmit(true, false, false, true, address(vault));
        emit BuySkipped(REACTIVE, 1, 2999999999, MAX_PRICE);
        _executeBuy();

        assertEq(MockPool(POOL).swapCount(), 0);
        assertEq(vault.buyCount(), 0);
    }

    function test_ExecuteBuySkipsWhenPriceHigh() public {
        MockPool(POOL).setSqrtPrice(SQRT_3300); // $3,300
        vm.prank(PROXY);
        vm.expectEmit(true, false, false, true, address(vault));
        emit BuySkipped(REACTIVE, 2, 3299999999, 3_000_000_000);
        vault.executeBuy(REACTIVE, AMOUNT_IN, 3_000_000_000); // max $3,000

        assertEq(MockPool(POOL).swapCount(), 0);
        assertEq(vault.buyCount(), 0);
    }

    function test_ExecuteBuySkipsWhenLowBalance() public {
        MockERC20(USDC).setBalance(address(vault), 500_000); // 0.5 USDC < 1 USDC
        vm.expectEmit(true, false, false, true, address(vault));
        emit BuySkipped(REACTIVE, 3, 2999999999, MAX_PRICE);
        _executeBuy();

        assertEq(MockPool(POOL).swapCount(), 0);
        assertEq(vault.buyCount(), 0);
    }

    function test_ExecuteBuySkipsWhenPriceZero() public {
        MockPool(POOL).setSqrtPrice(MAX_SQRT); // price truncates to 0
        vm.expectEmit(true, false, false, true, address(vault));
        emit BuySkipped(REACTIVE, 4, 0, MAX_PRICE);
        _executeBuy();

        assertEq(MockPool(POOL).swapCount(), 0);
        assertEq(vault.buyCount(), 0);
    }

    function test_BuyAtExactMaxPriceExecutes() public {
        // price == maxPrice is in-band (reactive gate is price <= maxPrice).
        vm.prank(PROXY);
        vault.executeBuy(REACTIVE, AMOUNT_IN, 2999999999);
        assertEq(vault.buyCount(), 1);
    }

    // ---- pause ----

    function test_SetPausedToggles() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit PausedSet(REACTIVE, true);
        _setPaused(true);
        assertTrue(vault.paused());
        _setPaused(false);
        assertFalse(vault.paused());
    }

    // ---- owner break-glass (F2) ----

    function test_ResumeGuardOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        vault.resumeGuard();
    }

    function test_ResumeGuardUnpauses() public {
        _setPaused(true);
        assertTrue(vault.paused());

        vm.expectEmit(false, false, false, true, address(vault));
        emit OwnerResumed();
        vault.resumeGuard();

        assertFalse(vault.paused());
    }

    // ---- owner withdrawals ----

    function test_WithdrawUSDCOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        vault.withdrawUSDC(1_000_000);
    }

    function test_WithdrawUSDCSendsToOwner() public {
        uint256 before = MockERC20(USDC).balanceOf(address(this));
        vault.withdrawUSDC(2_000_000);
        assertEq(MockERC20(USDC).balanceOf(address(this)), before + 2_000_000);
        assertEq(MockERC20(USDC).balanceOf(address(vault)), 8_000_000);
    }

    function test_WithdrawWETHOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        vault.withdrawWETH(1);
    }

    function test_WithdrawWETHSendsToOwner() public {
        MockERC20(WETH).setBalance(address(vault), 5 ether);
        vault.withdrawWETH(2 ether);
        assertEq(MockERC20(WETH).balanceOf(address(this)), 2 ether);
        assertEq(MockERC20(WETH).balanceOf(address(vault)), 3 ether);
    }

    // ---- debt (H3 runbook helper) ----

    function test_DebtViewReadsProxy() public {
        MockProxy(payable(PROXY)).setDebt(777);
        assertEq(vault.debt(), 777);
    }

    function test_CoverDebtPaysProxy() public {
        MockProxy(payable(PROXY)).setDebt(0.001 ether);
        vm.deal(address(vault), 0.01 ether);
        uint256 proxyBefore = address(PROXY).balance;
        vault.coverDebt();
        assertEq(address(PROXY).balance, proxyBefore + 0.001 ether);
    }

    function test_CoverDebtWithZeroDebtIsNoop() public {
        vm.deal(address(vault), 0.01 ether);
        vault.coverDebt(); // must not revert
        assertEq(address(vault).balance, 0.01 ether);
    }
}
