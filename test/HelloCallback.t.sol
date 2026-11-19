// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { HelloCallback } from "../src/HelloCallback.sol";

contract HelloCallbackTest is Test {
    address internal constant PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia callback proxy
    address internal constant REACTIVE = 0x00000000000000000000000000000000CA11bAC6;

    HelloCallback internal cb;

    event Pong(address indexed reactive, uint256 value, uint256 blockNumber);

    function setUp() public {
        cb = new HelloCallback(IPayable(payable(PROXY)), REACTIVE);
    }

    function test_PingFromProxySucceeds() public {
        vm.expectEmit(true, false, false, true, address(cb));
        emit Pong(REACTIVE, 1, block.number);

        vm.prank(PROXY);
        cb.ping(REACTIVE, 1);

        assertEq(cb.count(), 1);
        assertEq(cb.lastValue(), 1);
    }

    function test_PingFromNonProxyReverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        cb.ping(REACTIVE, 1);
        assertEq(cb.count(), 0);
    }

    function test_PingWithWrongSenderReverts() public {
        vm.prank(PROXY);
        vm.expectRevert();
        cb.ping(address(0xBEEF), 1);
        assertEq(cb.count(), 0);
    }

    function test_ServiceProviderIsProxy() public view {
        assertEq(address(cb._SERVICE_PROVIDER()), PROXY);
    }

    function test_CallbackSenderIsReactive() public view {
        assertEq(cb._CALLBACK_SENDER(), REACTIVE);
    }
}
