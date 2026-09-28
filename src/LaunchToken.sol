// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A separate launch token; it grants no claim on strategy assets.
contract LaunchToken is ERC20 {
    constructor() ERC20("Bitcoin Cooler", "BCLR") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
