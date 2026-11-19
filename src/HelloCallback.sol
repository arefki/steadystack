// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title HelloCallback — minimal callback receiver for the "hello reactive" proof.
/// @notice Deployed on the destination chain (Base Sepolia). `ping` may only be
/// called by the callback proxy on behalf of the paired reactive contract.
contract HelloCallback is AbstractCallback {
    uint256 public count;
    uint256 public lastValue;

    event Pong(address indexed reactive, uint256 value, uint256 blockNumber);

    constructor(IPayable callbackProxy_, address callbackSender_) AbstractCallback(callbackProxy_, callbackSender_) {}

    function ping(address reactive_, uint256 value_) external onlyServiceProvider onlyCallbackSender(reactive_) {
        count++;
        lastValue = value_;
        emit Pong(reactive_, value_, block.number);
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
