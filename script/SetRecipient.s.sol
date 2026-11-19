// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script } from "forge-std/Script.sol";
import { HelloReactive } from "../src/HelloReactive.sol";

/// @notice Points HelloReactive at the deployed HelloCallback (Base Sepolia).
/// Requires env: HELLO_REACTIVE_ADDR, HELLO_CALLBACK_ADDR.
/// Usage: forge script script/SetRecipient.s.sol --rpc-url lasna --broadcast
contract SetRecipient is Script {
    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        address payable reactive = payable(vm.envAddress("HELLO_REACTIVE_ADDR"));
        address callback = vm.envAddress("HELLO_CALLBACK_ADDR");
        vm.startBroadcast(pk);
        HelloReactive(reactive).setRecipient(84532, callback);
        vm.stopBroadcast();
    }
}
