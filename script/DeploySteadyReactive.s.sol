// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { SteadyReactive } from "../src/SteadyReactive.sol";

/// @notice Deploys SteadyReactive on Lasna (5318007), funded with 0.3 lREACT at deploy.
/// 0.3 lREACT covers ~30,000 CRON100 ticks at 100 gwei — far more than the
/// demo + judging window needs. (0.5 lREACT did NOT fit: forge's EIP-1559
/// estimate doubles the 100 gwei fee, pushing value+gas over the 0.70 balance.)
/// Usage: forge script script/DeploySteadyReactive.s.sol --rpc-url lasna --broadcast --legacy --gas-price 100000000000
contract DeploySteadyReactive is Script {
    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        vm.startBroadcast(pk);
        SteadyReactive reactive = new SteadyReactive{ value: 0.3 ether }();
        vm.stopBroadcast();
        console.log("SteadyReactive:", address(reactive));
    }
}
