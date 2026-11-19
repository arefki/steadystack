// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { SteadyVault } from "../src/SteadyVault.sol";

/// @notice Deploys SteadyVault on Base Sepolia (84532).
/// Requires env: STEADY_REACTIVE_ADDR (the deployed SteadyReactive on Lasna).
/// Usage: forge script script/DeploySteadyVault.s.sol --rpc-url base_sepolia --broadcast
contract DeploySteadyVault is Script {
    address internal constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        address reactive = vm.envAddress("STEADY_REACTIVE_ADDR");
        vm.startBroadcast(pk);
        SteadyVault vault = new SteadyVault(IPayable(payable(BASE_SEPOLIA_PROXY)), reactive);
        vm.stopBroadcast();
        console.log("SteadyVault:", address(vault));
    }
}
