// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { PriceMath } from "./PriceMath.sol";

/// @title SteadyReactive — Auto-DCA + Deterministic Crash Guard (Reactive Omni Buildathon).
/// @notice Lives on Lasna. Subscribes to (a) Swap events of the Uniswap V3
/// WETH/USDC 0.3% pool on Base Sepolia (price signal), (b) CRON100 ticks
/// (~2 min, the DCA schedule driver), and (c) Bought events from the paired
/// vault (confirmed fills update the guard reference). On each due event it
/// requests a callback to SteadyVault to execute one USDC -> WETH buy.
///
/// Design decisions (see helper-fanout-design-review-phase3.md):
/// - Price math: 6-dec fixed point via PriceMath (10^18 numerator; H1 fix).
/// - Guard is TWO-TIER: TRIP on the Swap event's spot price (immediate, visible),
///   RESUME on the EMA (hysteresis, no flapping). A Uniswap observe() TWAP is
///   impossible here — react() has no destination-chain reads.
/// - Guard reference updates ONLY on confirmed fills (vault Bought events),
///   never optimistically on request (D5 fix).
/// - intervalTicks >= 1 enforced: interval 0 would buy on every Swap event (D4 fix).
/// - The first buy is due as soon as a price exists; later buys respect the
///   tick interval. The due-check runs on Swap events too, not only CRON ticks,
///   so a buy fires on the first event after it becomes due (M2 fix).
/// - poke() is an owner-only demo aid that runs the due-check outside react().
///   Whether the system contract accepts callback requests outside react() is
///   UNVERIFIED — tested live after deploy; if it reverts, Swap/CRON triggers
///   remain the only paths.
contract SteadyReactive is AbstractReactive {
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    address internal constant POOL = 0x46880b404CD35c165EDdefF7421019F8dD25F4Ad;
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint64 internal constant CALLBACK_GAS_LIMIT = 1_000_000;

    // keccak256("Cron100(uint256)") — verified against the official docs table.
    uint256 internal constant CRON100_TOPIC_0 =
        0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    // keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)").
    uint256 internal constant SWAP_TOPIC_0 =
        0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67;
    // keccak256("Bought(address,uint256,uint256,uint256,uint256)").
    uint256 internal constant BOUGHT_TOPIC_0 =
        0x27330bd7589580547b6437e08f9c60653de63691d2d2b2c13bff9ee67da2a68d;

    address public immutable owner;
    uint256 public destChainId;
    address public recipient;
    bool public boughtSubscribed;

    struct Rule {
        uint256 amountIn; // USDC per buy, 6-dec raw
        uint256 maxPrice; // 6-dec fixed point USDC/WETH
        uint256 intervalTicks; // CRON100 ticks between buys, >= 1
        uint256 guardBps; // trip if spot < reference * (10000 - guardBps) / 10000
        uint256 resumeBps; // clear if ema > reference * (10000 - resumeBps) / 10000
        bool paused;
    }

    Rule public rule;

    uint256 public lastPrice; // 6-dec spot from the last Swap event
    uint256 public emaPrice; // 6-dec EMA over Swap-event prices (alpha 1/4)
    bool public emaInitialized;
    uint256 public referencePrice; // 6-dec guard reference (first price + confirmed fills)
    bool public referenceSet;
    bool public guardTripped;
    uint256 public tickCount;
    uint256 public lastBuyTick;
    bool public hasBought;
    uint256 public buyRequests;

    event RuleUpdated(uint256 amountIn, uint256 maxPrice, uint256 intervalTicks, uint256 guardBps, uint256 resumeBps);
    event PriceUpdated(uint256 price, uint256 ema);
    event BuyRequested(uint256 tick, uint256 amountIn, uint256 maxPrice);
    event GuardTripped(uint256 price, uint256 referencePrice);
    event GuardCleared(uint256 price, uint256 referencePrice);
    event GuardClearedByOwner();
    event RecipientSet(uint256 chainId, address recipient);
    event PausedSet(bool paused);

    error NotOwner();
    error ZeroAddress();
    error BadRule();

    constructor() payable {
        owner = msg.sender;
        SYSTEM.subscribe(
            BASE_SEPOLIA, POOL, SWAP_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(
            block.chainid, LEGACY_SYSTEM_ADDR, CRON100_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Configures the DCA rule. Preserves the paused flag.
    /// @dev intervalTicks >= 1 (interval 0 would buy on every Swap event);
    /// resumeBps < guardBps so the resume threshold sits above the trip threshold.
    function setRule(
        uint256 amountIn_,
        uint256 maxPrice_,
        uint256 intervalTicks_,
        uint256 guardBps_,
        uint256 resumeBps_
    ) external onlyOwner {
        if (amountIn_ == 0 || maxPrice_ == 0 || intervalTicks_ == 0) revert BadRule();
        if (guardBps_ >= 10000 || resumeBps_ >= guardBps_) revert BadRule();
        rule = Rule({
            amountIn: amountIn_,
            maxPrice: maxPrice_,
            intervalTicks: intervalTicks_,
            guardBps: guardBps_,
            resumeBps: resumeBps_,
            paused: rule.paused
        });
        emit RuleUpdated(amountIn_, maxPrice_, intervalTicks_, guardBps_, resumeBps_);
    }

    /// @notice Pauses/unpauses buy requests (the vault keeps its own pause flag,
    /// set via callback on guard trips).
    function setPaused(bool paused_) external onlyOwner {
        rule.paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Owner break-glass (F2, code review 2026-11-19): clears a stuck
    /// guard — e.g. no Swap events arrive to drive the EMA resume — and
    /// requests the vault unpause. If the price is still below the trip
    /// threshold, the guard re-trips on the next Swap event.
    function clearGuard() external onlyOwner {
        guardTripped = false;
        emit GuardClearedByOwner();
        _requestSetPaused(false);
    }

    /// @notice Sets the callback destination and subscribes to its Bought events
    /// (confirmed fills update the guard reference). Re-pointing moves the
    /// Bought subscription to the new vault.
    function setRecipient(uint256 chainId_, address recipient_) external onlyOwner {
        if (recipient_ == address(0)) revert ZeroAddress();
        emit RecipientSet(chainId_, recipient_);
        uint256 oldChainId = destChainId;
        address oldRecipient = recipient;
        bool wasSubscribed = boughtSubscribed;
        destChainId = chainId_;
        recipient = recipient_;
        boughtSubscribed = true;
        if (wasSubscribed && oldRecipient != recipient_) {
            SYSTEM.unsubscribe(
                oldChainId, oldRecipient, BOUGHT_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        if (!wasSubscribed || oldRecipient != recipient_) {
            SYSTEM.subscribe(
                chainId_, recipient_, BOUGHT_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    /// @notice Owner-only demo aid: runs the buy due-check outside react().
    /// Whether the system contract accepts callback requests outside react() is
    /// unverified — if this reverts on Lasna, use Swap/CRON triggers instead.
    function poke() external onlyOwner {
        _maybeBuy();
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 == SWAP_TOPIC_0) {
            if (log_.chainId != BASE_SEPOLIA || log_.contractAddress != POOL) return;
            _onSwap(log_);
        } else if (log_.topic0 == CRON100_TOPIC_0) {
            tickCount++;
            _maybeBuy();
        } else if (log_.topic0 == BOUGHT_TOPIC_0) {
            if (log_.chainId != destChainId || log_.contractAddress != recipient) return;
            _onBought(log_);
        }
        // Unknown topics are ignored (never revert as a filter: the system
        // still bills for the gas burned).
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Outstanding debt to the system contract (H3 runbook helper).
    function debt() external view returns (uint256) {
        return _SERVICE_PROVIDER.debt(address(this));
    }

    function _onSwap(LogRecord calldata log_) internal {
        (, , uint160 sqrtPriceX96, , ) =
            abi.decode(log_.data, (int256, int256, uint160, uint128, int24));
        uint256 price = PriceMath.priceFromSqrt(sqrtPriceX96);
        if (price == 0) return; // No usable price: skip everything.
        lastPrice = price;
        if (!emaInitialized) {
            emaPrice = price;
            emaInitialized = true;
        } else {
            emaPrice = (3 * emaPrice + price) / 4;
        }
        if (!referenceSet) {
            referencePrice = price;
            referenceSet = true;
        }
        emit PriceUpdated(price, emaPrice);
        _checkGuard(price);
        _maybeBuy();
    }

    /// @notice Two-tier guard: trip on SPOT price, resume on EMA.
    function _checkGuard(uint256 price_) internal {
        if (rule.amountIn == 0 || !referenceSet) return; // No rule configured yet.
        if (!guardTripped) {
            if (price_ < (referencePrice * (10000 - rule.guardBps)) / 10000) {
                guardTripped = true;
                // F1 (code review 2026-11-19, kiko): anchor the EMA at the crash
                // price on trip. Without this, a SHALLOW trip leaves the stale
                // pre-crash EMA above the resume threshold, and the very next
                // Swap event clears the guard instantly (verified numerically:
                // -11% trip left EMA 2,917,499,999 > threshold 2,849,999,999).
                // Recovery must now climb from the crash level — real hysteresis.
                emaPrice = price_;
                emit GuardTripped(price_, referencePrice);
                _requestSetPaused(true);
            }
        } else {
            if (emaPrice > (referencePrice * (10000 - rule.resumeBps)) / 10000) {
                guardTripped = false;
                emit GuardCleared(price_, referencePrice);
                _requestSetPaused(false);
            }
        }
    }

    function _onBought(LogRecord calldata log_) internal {
        (, , uint256 price, ) = abi.decode(log_.data, (uint256, uint256, uint256, uint256));
        if (price == 0) return;
        referencePrice = price;
        referenceSet = true;
    }

    /// @notice Shared due-check: first buy as soon as a price exists, later buys
    /// only after intervalTicks CRON ticks since the last buy.
    function _maybeBuy() internal {
        if (recipient == address(0)) return;
        if (rule.amountIn == 0) return;
        if (rule.paused) return;
        if (guardTripped) return;
        if (lastPrice == 0) return;
        if (lastPrice > rule.maxPrice) return;
        if (hasBought && tickCount - lastBuyTick < rule.intervalTicks) return;

        hasBought = true;
        lastBuyTick = tickCount;
        buyRequests++;
        // The system contract never calls back into this contract, so emitting
        // after a sibling function's external call cannot be reordered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BuyRequested(tickCount, rule.amountIn, rule.maxPrice);
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeWithSignature(
                    "executeBuy(address,uint256,uint256)", address(0), rule.amountIn, rule.maxPrice
                )
            })
        );
    }

    function _requestSetPaused(bool paused_) internal {
        if (recipient == address(0)) return;
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeWithSignature("setPaused(address,bool)", address(0), paused_)
            })
        );
    }
}
