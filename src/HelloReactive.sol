// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title HelloReactive — minimal "hello reactive" proof contract.
/// @notice Subscribes to Cron10 ticks on Lasna. On the first tick after a
/// recipient is set, it requests ONE callback to the destination contract and
/// unsubscribes, so it stops paying for ticks. Proves the full
/// event -> react() -> callback loop end-to-end before the real build.
contract HelloReactive is AbstractReactive {
    address internal constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant CRON10_TOPIC_0 =
        0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint64 internal constant CALLBACK_GAS_LIMIT = 1_000_000;

    address public immutable owner;
    uint256 public destChainId;
    address public recipient;
    bool public fired;

    event Fired(uint256 indexed chainId, address indexed recipient, uint256 value);

    error NotOwner();
    error AlreadyFired();
    error ZeroAddress();

    constructor() payable {
        owner = msg.sender;
        SYSTEM.subscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            CRON10_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Sets the callback destination. Must be called after deploying
    /// the callback contract (which needs this contract's address first).
    function setRecipient(uint256 chainId_, address recipient_) external onlyOwner {
        if (fired) revert AlreadyFired();
        if (recipient_ == address(0)) revert ZeroAddress();
        destChainId = chainId_;
        recipient = recipient_;
    }

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        if (log_.topic0 != CRON10_TOPIC_0) return;
        if (fired) return;
        if (recipient == address(0)) return;

        fired = true;
        emit Fired(destChainId, recipient, 1);
        SYSTEM.unsubscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            CRON10_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        bytes memory payload = abi.encodeWithSignature("ping(address,uint256)", address(0), uint256(1));
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destChainId,
                recipient: recipient,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
