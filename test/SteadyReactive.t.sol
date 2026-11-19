// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { SteadyReactive } from "../src/SteadyReactive.sol";

/// @notice Records SYSTEM calls so tests can assert subscriptions + callbacks.
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Sub[] public subscribes;
    Sub[] public unsubscribes;
    ISystemContract.CallbackConfiguration_V_1_0[] public callbackConfigs;
    uint256 public debtValue;

    function subscribe(uint256 chainId_, address contract_, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subscribes.push(Sub(chainId_, contract_, t0, t1, t2, t3));
    }

    function unsubscribe(uint256 chainId_, address contract_, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        unsubscribes.push(Sub(chainId_, contract_, t0, t1, t2, t3));
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackConfigs.push(config_);
    }

    function debt(address) external view returns (uint256) {
        return debtValue;
    }

    function reserves(address) external pure returns (uint256) {
        return 0;
    }

    function setDebt(uint256 v) external {
        debtValue = v;
    }

    function subscribeCount() external view returns (uint256) {
        return subscribes.length;
    }

    function unsubscribeCount() external view returns (uint256) {
        return unsubscribes.length;
    }

    function callbackCount() external view returns (uint256) {
        return callbackConfigs.length;
    }
}

contract SteadyReactiveTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    address internal constant POOL = 0x46880b404CD35c165EDdefF7421019F8dD25F4Ad;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    uint256 internal constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant SWAP_TOPIC_0 = 0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67;
    uint256 internal constant BOUGHT_TOPIC_0 = 0x27330bd7589580547b6437e08f9c60653de63691d2d2b2c13bff9ee67da2a68d;

    uint256 internal constant BASE_SEPOLIA = 84532;
    address internal constant VAULT = 0x00000000000000000000000000000000DeaDBeef;
    address internal constant VAULT2 = 0x00000000000000000000000000000000deadbeE0;

    // sqrtPriceX96 values (token0 = USDC, token1 = WETH) + their 6-dec prices.
    uint160 internal constant SQRT_3000 = 1446501726624926496477173928747178; // 2,999,999,999
    uint160 internal constant SQRT_2400 = 1617238095152076543778314735768381; // 2,399,999,999
    uint160 internal constant SQRT_2670 = 1533288763647961361737237090974160; // 2,669,999,999 (-11%)
    uint160 internal constant SQRT_2850 = 1484079457770972155084049015857918; // 2,849,999,999
    uint160 internal constant SQRT_3300 = 1379185281616022357605400610384815; // 3,299,999,999

    uint256 internal constant PRICE_3000 = 2999999999;
    uint256 internal constant PRICE_2400 = 2399999999;
    uint256 internal constant PRICE_2670 = 2669999999;

    // Default rule: 1 USDC/buy, max $30,000, every 1 tick, guard 10%, resume 5%.
    uint256 internal constant AMOUNT_IN = 1_000_000;
    uint256 internal constant MAX_PRICE = 30_000_000_000;
    uint256 internal constant INTERVAL = 1;
    uint256 internal constant GUARD_BPS = 1000;
    uint256 internal constant RESUME_BPS = 500;

    MockSystem internal mock;
    SteadyReactive internal reactive;

    event RuleUpdated(uint256 amountIn, uint256 maxPrice, uint256 intervalTicks, uint256 guardBps, uint256 resumeBps);
    event PriceUpdated(uint256 price, uint256 ema);
    event BuyRequested(uint256 tick, uint256 amountIn, uint256 maxPrice);
    event GuardTripped(uint256 price, uint256 referencePrice);
    event GuardCleared(uint256 price, uint256 referencePrice);
    event GuardClearedByOwner();
    event RecipientSet(uint256 chainId, address recipient);
    event PausedSet(bool paused);

    function setUp() public {
        mock = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mock).code);
        reactive = new SteadyReactive();
    }

    function _swapLog(uint160 sqrtP) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: POOL,
            topic0: SWAP_TOPIC_0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(int256(0), int256(0), sqrtP, uint128(0), int24(0)),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: block.chainid,
            contractAddress: LEGACY_SYSTEM_ADDR,
            topic0: CRON100_TOPIC_0,
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

    function _boughtLog(address from, uint256 price) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: BASE_SEPOLIA,
            contractAddress: from,
            topic0: BOUGHT_TOPIC_0,
            topic1: uint256(uint160(address(reactive))),
            topic2: 0,
            topic3: 0,
            data: abi.encode(AMOUNT_IN, uint256(333333333444444), price, block.number),
            blockNumber: block.number,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _setRule() internal {
        reactive.setRule(AMOUNT_IN, MAX_PRICE, INTERVAL, GUARD_BPS, RESUME_BPS);
    }

    function _react(IReactive.LogRecord memory log) internal {
        vm.prank(SYSTEM_ADDR);
        reactive.react(log);
    }

    function _sys() internal view returns (MockSystem) {
        return MockSystem(SYSTEM_ADDR);
    }

    // ---- subscriptions ----

    function test_ConstructorSubscribesToSwapAndCron() public view {
        MockSystem sys = _sys();
        assertEq(sys.subscribeCount(), 2);
        (uint256 c0, address a0, uint256 t0, uint256 t1, uint256 t2, uint256 t3) = sys.subscribes(0);
        assertEq(c0, BASE_SEPOLIA);
        assertEq(a0, POOL);
        assertEq(t0, SWAP_TOPIC_0);
        assertEq(t1, REACTIVE_IGNORE);
        assertEq(t2, REACTIVE_IGNORE);
        assertEq(t3, REACTIVE_IGNORE);
        (uint256 c1, address a1, uint256 u0,,,) = sys.subscribes(1);
        assertEq(c1, block.chainid);
        assertEq(a1, LEGACY_SYSTEM_ADDR);
        assertEq(u0, CRON100_TOPIC_0);
    }

    function test_SetRecipientSubscribesBought() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        MockSystem sys = _sys();
        assertEq(sys.subscribeCount(), 3);
        (uint256 c, address a, uint256 t0,,,) = sys.subscribes(2);
        assertEq(c, BASE_SEPOLIA);
        assertEq(a, VAULT);
        assertEq(t0, BOUGHT_TOPIC_0);
        assertEq(reactive.recipient(), VAULT);
        assertEq(reactive.destChainId(), BASE_SEPOLIA);
    }

    function test_SetRecipientTwiceMovesBoughtSubscription() public {
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        reactive.setRecipient(BASE_SEPOLIA, VAULT2);
        MockSystem sys = _sys();
        assertEq(sys.subscribeCount(), 4);
        assertEq(sys.unsubscribeCount(), 1);
        (uint256 c, address a, uint256 t0,,,) = sys.unsubscribes(0);
        assertEq(c, BASE_SEPOLIA);
        assertEq(a, VAULT);
        assertEq(t0, BOUGHT_TOPIC_0);
        (uint256 c2, address a2, uint256 t2,,,) = sys.subscribes(3);
        assertEq(c2, BASE_SEPOLIA);
        assertEq(a2, VAULT2);
        assertEq(t2, BOUGHT_TOPIC_0);
    }

    // ---- access control ----

    function test_ReactFromNonSystemReverts() public {
        vm.expectRevert();
        reactive.react(_cronLog());
    }

    function test_SetRuleOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        reactive.setRule(AMOUNT_IN, MAX_PRICE, INTERVAL, GUARD_BPS, RESUME_BPS);
    }

    function test_SetRecipientOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
    }

    function test_SetRecipientZeroAddressReverts() public {
        vm.expectRevert();
        reactive.setRecipient(BASE_SEPOLIA, address(0));
    }

    function test_PokeOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        reactive.poke();
    }

    function test_SetPausedOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        reactive.setPaused(true);
    }

    // ---- rule validation (design review D4: interval 0 rejected) ----

    function test_SetRuleRejectsZeroInterval() public {
        vm.expectRevert();
        reactive.setRule(AMOUNT_IN, MAX_PRICE, 0, GUARD_BPS, RESUME_BPS);
    }

    function test_SetRuleRejectsZeroAmount() public {
        vm.expectRevert();
        reactive.setRule(0, MAX_PRICE, INTERVAL, GUARD_BPS, RESUME_BPS);
    }

    function test_SetRuleRejectsZeroMaxPrice() public {
        vm.expectRevert();
        reactive.setRule(AMOUNT_IN, 0, INTERVAL, GUARD_BPS, RESUME_BPS);
    }

    function test_SetRuleRejectsGuardBpsAt10000() public {
        vm.expectRevert();
        reactive.setRule(AMOUNT_IN, MAX_PRICE, INTERVAL, 10000, RESUME_BPS);
    }

    function test_SetRuleRejectsResumeBpsNotBelowGuard() public {
        // resume threshold must sit ABOVE the trip threshold (resumeBps < guardBps).
        vm.expectRevert();
        reactive.setRule(AMOUNT_IN, MAX_PRICE, INTERVAL, GUARD_BPS, GUARD_BPS);
        vm.expectRevert();
        reactive.setRule(AMOUNT_IN, MAX_PRICE, INTERVAL, GUARD_BPS, GUARD_BPS + 1);
    }

    function test_SetRuleStoresRuleAndEmits() public {
        vm.expectEmit(false, false, false, true, address(reactive));
        emit RuleUpdated(AMOUNT_IN, MAX_PRICE, INTERVAL, GUARD_BPS, RESUME_BPS);
        _setRule();
        (uint256 amountIn, uint256 maxPrice, uint256 interval, uint256 guardBps, uint256 resumeBps, bool paused) =
            reactive.rule();
        assertEq(amountIn, AMOUNT_IN);
        assertEq(maxPrice, MAX_PRICE);
        assertEq(interval, INTERVAL);
        assertEq(guardBps, GUARD_BPS);
        assertEq(resumeBps, RESUME_BPS);
        assertFalse(paused);
    }

    // ---- price + EMA ----

    function test_SwapUpdatesPriceEmaAndReference() public {
        _react(_swapLog(SQRT_3000));
        assertEq(reactive.lastPrice(), PRICE_3000);
        assertEq(reactive.emaPrice(), PRICE_3000);
        assertTrue(reactive.emaInitialized());
        assertEq(reactive.referencePrice(), PRICE_3000);
        assertTrue(reactive.referenceSet());
    }

    function test_EmaLagsSpot() public {
        _react(_swapLog(SQRT_3000));
        _react(_swapLog(SQRT_2400));
        // ema = (3*2999999999 + 2399999999) / 4 = 2849999999
        assertEq(reactive.lastPrice(), PRICE_2400);
        assertEq(reactive.emaPrice(), 2849999999);
    }

    function test_PriceZeroSkipped() public {
        _react(_swapLog(0));
        assertEq(reactive.lastPrice(), 0);
        assertFalse(reactive.referenceSet());
        assertFalse(reactive.emaInitialized());
    }

    function test_SwapFromWrongPoolIgnored() public {
        IReactive.LogRecord memory log = _swapLog(SQRT_3000);
        log.contractAddress = address(0x1234);
        _react(log);
        assertEq(reactive.lastPrice(), 0);
        assertFalse(reactive.referenceSet());
    }

    function test_NonMatchingLogIgnored() public {
        IReactive.LogRecord memory log = _cronLog();
        log.topic0 = 0xdeadbeef;
        _react(log);
        assertEq(reactive.tickCount(), 0);
    }

    // ---- guard (two-tier: trip on SPOT, resume on EMA) ----

    function test_GuardTripsOnSpotDrop() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000)); // reference = 3000, buy #1 requested
        assertEq(_sys().callbackCount(), 1);

        vm.expectEmit(false, false, false, true, address(reactive));
        emit GuardTripped(PRICE_2400, PRICE_3000);
        _react(_swapLog(SQRT_2400)); // -20% spot vs 10% guard -> trip

        assertTrue(reactive.guardTripped());
        assertEq(_sys().callbackCount(), 2);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = _sys().callbackConfigs(1);
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(recipient, VAULT);
        assertEq(gasLimit, 1_000_000);
        assertEq(payload, abi.encodeWithSignature("setPaused(address,bool)", address(0), true));
    }

    function test_GuardDoesNotTripOnSmallDrop() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000));
        _react(_swapLog(SQRT_2850)); // -5% vs 10% guard -> no trip
        assertFalse(reactive.guardTripped());
        assertEq(_sys().callbackCount(), 1); // only the buy
    }

    function test_GuardClearsOnEmaRecovery() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000));
        _react(_swapLog(SQRT_2400)); // trip; EMA RESET to the crash price (F1)
        assertTrue(reactive.guardTripped());

        // Recovery is gradual: EMA climbs 2550 -> 2662.5 -> 2746.9 -> 2810.2
        // -> 2857.6, clearing only on the 5th Swap at $3,000 (threshold 2850).
        for (uint256 i = 0; i < 4; i++) {
            _react(_swapLog(SQRT_3000));
            assertTrue(reactive.guardTripped());
        }
        vm.expectEmit(false, false, false, true, address(reactive));
        emit GuardCleared(PRICE_3000, PRICE_3000);
        _react(_swapLog(SQRT_3000));

        assertFalse(reactive.guardTripped());
        assertEq(_sys().callbackCount(), 3);
        (,,, bytes memory payload) = _sys().callbackConfigs(2);
        assertEq(payload, abi.encodeWithSignature("setPaused(address,bool)", address(0), false));
    }

    /// @notice F1 regression (kiko's finding, code review 2026-11-19): a SHALLOW
    /// trip (-11%) must NOT clear on the very next same-price Swap. Before the
    /// fix the stale pre-crash EMA (2,917,499,999) sat above the resume
    /// threshold (2,849,999,999), so the second 2670 Swap cleared instantly.
    /// After the fix the trip resets the EMA to the crash price.
    function test_GuardStaysTrippedAfterShallowTrip() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000)); // reference = 3000
        _react(_swapLog(SQRT_2670)); // -11% vs 10% guard -> trip
        assertTrue(reactive.guardTripped());
        assertEq(reactive.emaPrice(), PRICE_2670); // EMA reset to crash price

        _react(_swapLog(SQRT_2670)); // same crashed price again
        assertTrue(reactive.guardTripped()); // must NOT clear
        assertEq(_sys().callbackCount(), 2); // buy + pause only, no unpause
    }

    function test_TripResetsEmaToCrashPrice() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000));
        _react(_swapLog(SQRT_2400)); // trip
        assertTrue(reactive.guardTripped());
        assertEq(reactive.emaPrice(), PRICE_2400); // EMA anchored at the crash
    }

    // ---- owner break-glass (F2) ----

    function test_ClearGuardOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        reactive.clearGuard();
    }

    function test_ClearGuardResetsAndUnpauses() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000));
        _react(_swapLog(SQRT_2400)); // trip
        assertTrue(reactive.guardTripped());
        assertEq(_sys().callbackCount(), 2); // buy + pause

        vm.expectEmit(false, false, false, true, address(reactive));
        emit GuardClearedByOwner();
        reactive.clearGuard();

        assertFalse(reactive.guardTripped());
        assertEq(_sys().callbackCount(), 3);
        (,,, bytes memory payload) = _sys().callbackConfigs(2);
        assertEq(payload, abi.encodeWithSignature("setPaused(address,bool)", address(0), false));
    }

    // ---- DCA due-check ----

    function test_FirstBuyDueImmediately() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);

        vm.expectEmit(false, false, false, true, address(reactive));
        emit BuyRequested(0, AMOUNT_IN, MAX_PRICE);
        _react(_swapLog(SQRT_3000));

        assertTrue(reactive.hasBought());
        assertEq(reactive.buyRequests(), 1);
        assertEq(reactive.lastBuyTick(), 0);
        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) = _sys().callbackConfigs(0);
        assertEq(chainId, BASE_SEPOLIA);
        assertEq(recipient, VAULT);
        assertEq(gasLimit, 1_000_000);
        assertEq(payload, abi.encodeWithSignature("executeBuy(address,uint256,uint256)", address(0), AMOUNT_IN, MAX_PRICE));
    }

    function test_NoDoubleBuyWithinInterval() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000));
        _react(_swapLog(SQRT_3000));
        _react(_swapLog(SQRT_3000));
        assertEq(_sys().callbackCount(), 1);
        assertEq(reactive.buyRequests(), 1);
    }

    function test_BuyDueAgainAfterInterval() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000)); // buy #1 at tick 0
        _react(_cronLog()); // tick 1 -> due -> buy #2
        assertEq(reactive.tickCount(), 1);
        assertEq(_sys().callbackCount(), 2);
        assertEq(reactive.lastBuyTick(), 1);
        _react(_cronLog()); // tick 2 -> due -> buy #3
        assertEq(_sys().callbackCount(), 3);
    }

    function test_SwapTriggersBuyWhenDue() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000)); // buy #1
        _react(_cronLog()); // tick 1, buy #2 fires on the tick itself
        assertEq(_sys().callbackCount(), 2);
        // Now advance a tick WITHOUT a buy: pause, tick, unpause, then a Swap fires it.
        reactive.setPaused(true);
        _react(_cronLog()); // tick 2, paused -> no buy
        assertEq(_sys().callbackCount(), 2);
        reactive.setPaused(false);
        _react(_swapLog(SQRT_3000)); // Swap (not a tick) fires the due buy #3
        assertEq(_sys().callbackCount(), 3);
        assertEq(reactive.lastBuyTick(), 2);
    }

    function test_BuyBlockedAboveMaxPrice() public {
        reactive.setRule(AMOUNT_IN, 3_000_000_000, INTERVAL, GUARD_BPS, RESUME_BPS); // max $3,000
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3300)); // $3,300 > max
        assertEq(_sys().callbackCount(), 0);
        _react(_cronLog());
        assertEq(_sys().callbackCount(), 0);
    }

    function test_BuyBlockedWhenPaused() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        reactive.setPaused(true);
        _react(_swapLog(SQRT_3000));
        _react(_cronLog());
        assertEq(_sys().callbackCount(), 0);
    }

    function test_BuyBlockedWhenGuardTripped() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000)); // buy #1
        _react(_swapLog(SQRT_2400)); // trip (pause callback #2)
        _react(_cronLog()); // tick 1, guarded -> no buy
        _react(_cronLog()); // tick 2, guarded -> no buy
        assertEq(_sys().callbackCount(), 2);
        assertEq(reactive.buyRequests(), 1);
    }

    function test_NoBuyWithoutRecipient() public {
        _setRule();
        _react(_swapLog(SQRT_3000));
        assertEq(reactive.lastPrice(), PRICE_3000);
        assertEq(_sys().callbackCount(), 0);
    }

    function test_NoBuyWithoutPrice() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_cronLog());
        assertEq(reactive.tickCount(), 1);
        assertEq(_sys().callbackCount(), 0);
    }

    function test_CronTickIncrementsTickCount() public {
        _react(_cronLog());
        _react(_cronLog());
        assertEq(reactive.tickCount(), 2);
    }

    // ---- Bought events update the reference (design review D5) ----

    function test_BoughtUpdatesReference() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000));
        assertEq(reactive.referencePrice(), PRICE_3000);
        _react(_boughtLog(VAULT, 2800000000));
        assertEq(reactive.referencePrice(), 2800000000);
    }

    function test_BoughtFromOtherContractIgnored() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000));
        _react(_boughtLog(address(0x9999), 1000000000));
        assertEq(reactive.referencePrice(), PRICE_3000);
    }

    // ---- poke (owner demo aid) ----

    function test_PokeRequestsBuyWhenDue() public {
        reactive.setRule(AMOUNT_IN, 1_000_000_000, INTERVAL, GUARD_BPS, RESUME_BPS); // max $1,000 blocks buys
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        _react(_swapLog(SQRT_3000)); // price set, no buy (above max)
        assertEq(_sys().callbackCount(), 0);
        reactive.setRule(AMOUNT_IN, MAX_PRICE, INTERVAL, GUARD_BPS, RESUME_BPS); // now in range
        reactive.poke();
        assertEq(_sys().callbackCount(), 1);
        (,,, bytes memory payload) = _sys().callbackConfigs(0);
        assertEq(payload, abi.encodeWithSignature("executeBuy(address,uint256,uint256)", address(0), AMOUNT_IN, MAX_PRICE));
    }

    function test_PokeDoesNothingWhenNotDue() public {
        _setRule();
        reactive.setRecipient(BASE_SEPOLIA, VAULT);
        reactive.poke(); // no price yet
        assertEq(_sys().callbackCount(), 0);
    }

    // ---- debt view (H3 runbook helper) ----

    function test_DebtViewReadsSystem() public {
        MockSystem(SYSTEM_ADDR).setDebt(12345);
        assertEq(reactive.debt(), 12345);
    }

    function test_SetPausedEmitsAndStores() public {
        vm.expectEmit(false, false, false, true, address(reactive));
        emit PausedSet(true);
        reactive.setPaused(true);
        (,,,,, bool paused) = reactive.rule();
        assertTrue(paused);
    }
}
