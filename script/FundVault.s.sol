// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
}

interface IPoolMinimal {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice One-off helper: swaps WETH -> USDC directly against the pool and
/// sends the USDC to a chosen recipient (the vault). An EOA cannot answer the
/// pool's swap callback, so a contract must do the swap.
/// Kept in script/ (deploy-time tooling, not part of the submission).
contract SwapHelper {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant POOL = 0x46880b404CD35c165EDdefF7421019F8dD25F4Ad;
    // For oneForZero (token1 -> token0) the limit must be ABOVE the current
    // sqrtP; MAX_SQRT_RATIO - 1 is the effectively-unlimited bound.
    uint160 internal constant SQRT_LIMIT_ONE_FOR_ZERO = 1461446703485210103287273052203988822378723970341;

    error NotPool();

    /// @notice Swaps `wethIn_` WETH (held by this contract) for USDC, paid
    /// directly to `recipient_`. Returns the USDC received.
    function swapWethForUsdc(uint256 wethIn_, address recipient_) external returns (uint256) {
        uint256 before = IERC20Minimal(USDC).balanceOf(recipient_);
        IPoolMinimal(POOL).swap(
            recipient_, false, int256(wethIn_), SQRT_LIMIT_ONE_FOR_ZERO, ""
        );
        return IERC20Minimal(USDC).balanceOf(recipient_) - before;
    }

    /// @notice Swaps `usdcIn_` USDC (held by this contract) for WETH, paid
    /// directly to `recipient_`. Returns the WETH received. Used by the
    /// guard-resume test to buy the price back up.
    function swapUsdcForWeth(uint256 usdcIn_, address recipient_) external returns (uint256) {
        uint256 before = IERC20Minimal(WETH).balanceOf(recipient_);
        IPoolMinimal(POOL).swap(
            recipient_, true, int256(usdcIn_), 4295128740, "" // MIN_SQRT_RATIO + 1 (pool rejects 0)
        );
        return IERC20Minimal(WETH).balanceOf(recipient_) - before;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != POOL) revert NotPool();
        if (amount0Delta > 0) IERC20Minimal(USDC).transfer(POOL, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20Minimal(WETH).transfer(POOL, uint256(amount1Delta));
    }
}

/// @notice Funds the SteadyVault with testnet USDC: wraps 0.001 Base Sepolia
/// ETH -> WETH, swaps 0.0005 WETH -> ~13 USDC into the vault, leaves 0.0005
/// WETH in the helper for the guard-trip demo (selling WETH pushes the price
/// down). Requires env: STEADY_VAULT_ADDR.
/// Usage: forge script script/FundVault.s.sol --rpc-url base_sepolia --broadcast
contract FundVault is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        address vault = vm.envAddress("STEADY_VAULT_ADDR");
        vm.startBroadcast(pk);
        IWETH9(WETH).deposit{ value: 0.001 ether }();
        SwapHelper helper = new SwapHelper();
        IERC20Minimal(WETH).transfer(address(helper), 0.001 ether);
        uint256 usdcOut = helper.swapWethForUsdc(0.0005 ether, vault);
        vm.stopBroadcast();
        console.log("SwapHelper:", address(helper));
        console.log("USDC to vault:", usdcOut);
    }
}
