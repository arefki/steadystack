// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { HelloReactive } from "../src/HelloReactive.sol";

/// @notice Records requestCallbackV_1_0 calls so tests can assert the reactive
/// contract actually requested a callback (the real system contract is replaced
/// with this mock via vm.etch in setUp).
contract MockSystem {
    uint256 public callbackRequests;
    ISystemContract.CallbackConfiguration_V_1_0 public lastConfig;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests++;
        lastConfig = config_;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }
}

contract HelloReactiveTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON10_TOPIC_0 =
        0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    uint256 internal constant BASE_SEPOLIA = 84532;
    address internal constant CALLBACK_ADDR = 0x00000000000000000000000000000000DeaDBeef;

    MockSystem internal mock;
    HelloReactive internal hello;

    event Fired(uint256 indexed chainId, address indexed recipient, uint256 value);

    function setUp() public {
        mock = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        hello = new HelloReactive();
    }

    function _cron10Log() internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: block.chainid,
            contractAddress: LEGACY_SYSTEM_ADDR,
            topic0: CRON10_TOPIC_0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint256(100)),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function test_ReactFromNonSystemReverts() public {
        vm.expectRevert();
        hello.react(_cron10Log());
    }

    function test_CronTickWithNoRecipientDoesNothing() public {
        vm.prank(SYSTEM_ADDR);
        hello.react(_cron10Log());
        assertFalse(hello.fired());
        assertEq(MockSystem(SYSTEM_ADDR).callbackRequests(), 0);
    }

    function test_CronTickRequestsCallbackOnce() public {
        hello.setRecipient(BASE_SEPOLIA, CALLBACK_ADDR);

        vm.expectEmit(true, true, false, true, address(hello));
        emit Fired(BASE_SEPOLIA, CALLBACK_ADDR, 1);

        vm.prank(SYSTEM_ADDR);
        hello.react(_cron10Log());

        assertTrue(hello.fired());
        MockSystem sys = MockSystem(SYSTEM_ADDR);
        assertEq(sys.callbackRequests(), 1);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = sys.lastConfig();
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(recipient, CALLBACK_ADDR);
        assertEq(gasLimit, 1_000_000);
        // payload = ping(address(0), 1) — first arg is the placeholder the
        // network replaces with the reactive contract's address.
        assertEq(payload, abi.encodeWithSignature("ping(address,uint256)", address(0), uint256(1)));
    }

    function test_SecondCronTickDoesNotRequestAgain() public {
        hello.setRecipient(BASE_SEPOLIA, CALLBACK_ADDR);

        vm.prank(SYSTEM_ADDR);
        hello.react(_cron10Log());
        vm.prank(SYSTEM_ADDR);
        hello.react(_cron10Log());

        assertEq(MockSystem(SYSTEM_ADDR).callbackRequests(), 1);
    }

    function test_NonCronLogIsIgnored() public {
        hello.setRecipient(BASE_SEPOLIA, CALLBACK_ADDR);
        IReactive.LogRecord memory log = _cron10Log();
        log.topic0 = 0xdeadbeef;

        vm.prank(SYSTEM_ADDR);
        hello.react(log);

        assertFalse(hello.fired());
        assertEq(MockSystem(SYSTEM_ADDR).callbackRequests(), 0);
    }

    function test_SetRecipientOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hello.setRecipient(BASE_SEPOLIA, CALLBACK_ADDR);
    }

    function test_SetRecipientAfterFiredReverts() public {
        hello.setRecipient(BASE_SEPOLIA, CALLBACK_ADDR);
        vm.prank(SYSTEM_ADDR);
        hello.react(_cron10Log());

        vm.expectRevert();
        hello.setRecipient(BASE_SEPOLIA, address(0x1234));
    }
}
