// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { SwapHelper } from "./FundVault.s.sol";

interface IERC20Minimal2 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETH9_2 {
    function deposit() external payable;
}

/// @notice Deploys a fresh SwapHelper (with swapUsdcForWeth) and funds it
/// with 0.001 WETH for the guard trip/resume test.
/// Usage: forge script script/DeploySwapHelper.s.sol --tc DeploySwapHelper --rpc-url base_sepolia --broadcast
contract DeploySwapHelper is Script {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        vm.startBroadcast(pk);
        IWETH9_2(WETH).deposit{ value: 0.001 ether }();
        SwapHelper helper = new SwapHelper();
        IERC20Minimal2(WETH).transfer(address(helper), 0.001 ether);
        vm.stopBroadcast();
        console.log("SwapHelper:", address(helper));
    }
}
