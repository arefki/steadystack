// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Script, console } from "forge-std/Script.sol";
import { SteadyReactive } from "../src/SteadyReactive.sol";

/// @notice Points SteadyReactive at the deployed SteadyVault + sets the DCA rule.
/// Requires env: STEADY_REACTIVE_ADDR, STEADY_VAULT_ADDR.
/// Rule (live demo): 1 USDC/buy, max $30,000, every 1 CRON100 tick (~2 min),
/// guard 10%, resume 5%. Live pool price ~$26,547/WETH (2026-11-19).
/// Usage: forge script script/SetupSteady.s.sol --rpc-url lasna --broadcast
contract SetupSteady is Script {
    function run() external {
        uint256 pk = vm.envUint("TESTNET_PRIVATE_KEY");
        address payable reactive = payable(vm.envAddress("STEADY_REACTIVE_ADDR"));
        address vault = vm.envAddress("STEADY_VAULT_ADDR");
        vm.startBroadcast(pk);
        SteadyReactive(reactive).setRecipient(84532, vault);
        SteadyReactive(reactive).setRule(1_000_000, 30_000_000_000, 1, 1000, 500);
        vm.stopBroadcast();
        console.log("SteadyReactive configured:", reactive);
        console.log("Vault:", vault);
    }
}
