// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoopPosition} from "./LoopPosition.sol";

/// @notice Creates full immutable accounts. Separating creation code keeps the receipt under EIP-170.
contract LoopAccountDeployer {
    address public immutable config;

    constructor(address config_) {
        require(config_.code.length != 0, "invalid config");
        config = config_;
    }

    function deploy(uint256 receiptId) external returns (address) {
        return address(new LoopPosition(config, msg.sender, receiptId));
    }
}
