// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { HelloCallback } from "../src/HelloCallback.sol";

/// @notice Deploys HelloCallback on Base Sepolia (84532).
/// Requires env: HELLO_REACTIVE_ADDR (the deployed HelloReactive on Lasna).
/// Usage: forge script script/DeployHelloCallback.s.sol --rpc-url base_sepolia --broadcast
contract DeployHelloCallback is Script {
    address internal constant BASE_SEPOLIA_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;

    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        address reactive = vm.envAddress("HELLO_REACTIVE_ADDR");
        vm.startBroadcast(pk);
        HelloCallback cb = new HelloCallback(IPayable(payable(BASE_SEPOLIA_PROXY)), reactive);
        vm.stopBroadcast();
        console.log("HelloCallback:", address(cb));
    }
}
