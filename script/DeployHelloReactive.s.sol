// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { HelloReactive } from "../src/HelloReactive.sol";

/// @notice Deploys HelloReactive on Lasna (5318007), funded with 0.5 lREACT at deploy.
/// Usage: forge script script/DeployHelloReactive.s.sol --rpc-url lasna --broadcast
contract DeployHelloReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        vm.startBroadcast(pk);
        HelloReactive hello = new HelloReactive{ value: 0.5 ether }();
        vm.stopBroadcast();
        console.log("HelloReactive:", address(hello));
    }
}
