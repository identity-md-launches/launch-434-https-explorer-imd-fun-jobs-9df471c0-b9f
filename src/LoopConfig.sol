// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFxManager, IFxPool, ICooler, IStaking, IPriceFeed} from "./interfaces/Protocols.sol";

/// @notice Fully configured at deployment, with no setters or privileged account.
contract LoopConfig {
    address public immutable wbtc;
    address public immutable fxUSD;
    address public immutable ohm;
    address public immutable gohm;
    address public immutable usds;
    address public immutable manager;
    address public immutable pool;
    address public immutable cooler;
    address public immutable staking;
    address public immutable router;
    address public immutable morpho;
    address public immutable priceFeed;
    uint256 public immutable maxPriceAge;

    error InvalidConfiguration();

    constructor(
        address wbtc_,
        address fxUSD_,
        address ohm_,
        address gohm_,
        address usds_,
        address manager_,
        address pool_,
        address cooler_,
        address staking_,
        address router_,
        address morpho_,
        address priceFeed_,
        uint256 maxPriceAge_
    ) {
        address[12] memory dependencies = [
            wbtc_, fxUSD_, ohm_, gohm_, usds_, manager_, pool_, cooler_, staking_, router_, morpho_, priceFeed_
        ];
        for (uint256 i; i < dependencies.length; ++i) {
            if (dependencies[i] == address(0)) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) {
                if (dependencies[i] == dependencies[j]) revert InvalidConfiguration();
            }
        }
        if (maxPriceAge_ == 0 || maxPriceAge_ > 7 days) revert InvalidConfiguration();
        wbtc = wbtc_;
        fxUSD = fxUSD_;
        ohm = ohm_;
        gohm = gohm_;
        usds = usds_;
        manager = manager_;
        pool = pool_;
        cooler = cooler_;
        staking = staking_;
        router = router_;
        morpho = morpho_;
        priceFeed = priceFeed_;
        maxPriceAge = maxPriceAge_;
    }

    /// @notice Recheck external bindings before funds are accepted, and during deployment rehearsal.
    /// @dev Constructors store addresses without assuming upstream contracts exist on the launch chain.
    function validate() external view {
        address[12] memory dependencies =
            [wbtc, fxUSD, ohm, gohm, usds, manager, pool, cooler, staking, router, morpho, priceFeed];
        for (uint256 i; i < dependencies.length; ++i) {
            if (dependencies[i].code.length == 0) revert InvalidConfiguration();
        }
        if (
            IERC20Metadata(wbtc).decimals() != 8 || IERC20Metadata(fxUSD).decimals() != 18
                || IERC20Metadata(ohm).decimals() != 9 || IERC20Metadata(gohm).decimals() != 18
                || IERC20Metadata(usds).decimals() != 18 || IPriceFeed(priceFeed).decimals() != 8
        ) revert InvalidConfiguration();
        if (
            IFxPool(pool).collateralToken() != wbtc || IFxPool(pool).poolManager() != manager
                || IFxManager(manager).fxUSD() != fxUSD || IFxManager(manager).getTokenScalingFactor(wbtc) != 1e28
                || ICooler(cooler).collateralToken() != gohm || ICooler(cooler).debtToken() != usds
                || ICooler(cooler).ohm() != ohm || ICooler(cooler).staking() != staking
                || IStaking(staking).OHM() != ohm || IStaking(staking).gOHM() != gohm
        ) revert InvalidConfiguration();
        (uint256 minRatio, uint256 maxRatio) = IFxPool(pool).getDebtRatioRange();
        if (minRatio > 0.33e18 || maxRatio < 0.5e18) revert InvalidConfiguration();
    }
}
