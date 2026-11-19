// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test, console } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { SteadyVault } from "../src/SteadyVault.sol";

/// @notice Fork test: a REAL USDC->WETH swap on Base Sepolia against the live
/// canonical pool. Run with:
///   BASE_SEPOLIA_RPC=<rpc> forge test --match-contract SteadyVaultForkTest
/// (uses vm.createFork, so it needs network access; skipped from the default
/// suite run when the env var is unset.)
contract SteadyVaultForkTest is Test {
    address internal constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant REACTIVE = 0x00000000000000000000000000000000DeaDBeef;

    SteadyVault internal vault;

    event Bought(address indexed reactive, uint256 amountIn, uint256 amountOut, uint256 price, uint256 blockNumber);

    function setUp() public {
        string memory rpc = vm.envOr("BASE_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
        vault = new SteadyVault(IPayable(payable(PROXY)), REACTIVE);
        deal(USDC, address(vault), 10_000_000); // 10 USDC
    }

    function test_RealSwapExecutes() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(vault));
        uint256 gasBefore = gasleft();

        vm.prank(PROXY);
        vault.executeBuy(REACTIVE, 1_000_000, 100_000_000_000); // 1 USDC, max $100k

        uint256 gasUsed = gasBefore - gasleft();
        console.log("executeBuy gas (real swap):", gasUsed);

        assertEq(vault.buyCount(), 1);
        uint256 wethAfter = IERC20(WETH).balanceOf(address(vault));
        assertGt(wethAfter, wethBefore);
        // At the live pool price (~$26.5k/WETH), 1 USDC buys ~3.7e13 wei WETH.
        // Sanity band: between 1e13 and 1e14 wei.
        uint256 bought = wethAfter - wethBefore;
        assertGe(bought, 1e13);
        assertLe(bought, 1e14);
        // Must fit comfortably inside the 1M callback gasLimit (minus ~150k
        // proxy deductions => ~850k forwarded).
        assertLt(gasUsed, 850_000);
    }

    function test_RealSwapSkipsAboveMaxPrice() public {
        vm.prank(PROXY);
        vault.executeBuy(REACTIVE, 1_000_000, 1_000_000); // max $1, way below live price
        assertEq(vault.buyCount(), 0);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}
