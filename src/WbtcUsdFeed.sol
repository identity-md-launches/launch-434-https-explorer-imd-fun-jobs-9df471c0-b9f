// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceFeed} from "./interfaces/Protocols.sol";

/// @notice WBTC/USD = WBTC/BTC * BTC/USD. Each component has its own immutable freshness limit.
contract WbtcUsdFeed {
    IPriceFeed public immutable wbtcBtc;
    IPriceFeed public immutable btcUsd;
    uint256 public immutable wbtcMaxAge;
    uint256 public immutable btcMaxAge;
    error InvalidPrice();

    constructor(address wbtcBtc_, address btcUsd_, uint256 wbtcMaxAge_, uint256 btcMaxAge_) {
        require(wbtcBtc_ != address(0) && btcUsd_ != address(0) && wbtcBtc_ != btcUsd_, "invalid feed");
        require(wbtcMaxAge_ != 0 && btcMaxAge_ != 0 && wbtcMaxAge_ <= 7 days && btcMaxAge_ <= 7 days, "feed age");
        wbtcBtc = IPriceFeed(wbtcBtc_);
        btcUsd = IPriceFeed(btcUsd_);
        wbtcMaxAge = wbtcMaxAge_;
        btcMaxAge = btcMaxAge_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        (uint256 a, uint256 ta) = _read(wbtcBtc, wbtcMaxAge);
        (uint256 b, uint256 tb) = _read(btcUsd, btcMaxAge);
        uint256 value = Math.mulDiv(a, b, 1e8);
        if (value == 0 || value > uint256(type(int256).max)) revert InvalidPrice();
        uint256 timestamp = Math.min(ta, tb);
        return (1, int256(value), timestamp, timestamp, 1);
    }

    function _read(IPriceFeed feed, uint256 maxAge) private view returns (uint256, uint256) {
        if (address(feed).code.length == 0 || feed.decimals() != 8) revert InvalidPrice();
        (uint80 round, int256 answer,, uint256 updated, uint80 answeredRound) = feed.latestRoundData();
        if (
            answer <= 0 || updated == 0 || updated > block.timestamp || answeredRound < round
                || block.timestamp - updated > maxAge
        ) revert InvalidPrice();
        return (uint256(answer), updated);
    }
}
