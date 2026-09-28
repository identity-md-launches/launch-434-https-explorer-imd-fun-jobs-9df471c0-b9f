// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IFxManager {
    function fxUSD() external view returns (address);
    function getTokenScalingFactor(address token) external view returns (uint256);
    function operate(address pool, uint256 id, int256 collateral, int256 debt) external returns (uint256);
}

interface IFxPool {
    function collateralToken() external view returns (address);
    function poolManager() external view returns (address);
    function getPosition(uint256 id) external view returns (uint256 rawCollateral, uint256 debt);
    function getPositionDebtRatio(uint256 id) external view returns (uint256);
    function getDebtRatioRange() external view returns (uint256, uint256);
}

interface IStaking {
    function OHM() external view returns (address);
    function gOHM() external view returns (address);
    function stake(address to, uint256 amount, bool rebasing, bool claim) external returns (uint256);
    function unstake(address to, uint256 amount, bool trigger, bool rebasing) external returns (uint256);
}

interface ICooler {
    struct DelegationRequest {
        address delegate;
        int256 amount;
    }

    struct AccountPosition {
        uint256 collateral;
        uint256 currentDebt;
        uint256 maxOriginationDebtAmount;
        uint256 liquidationDebtAmount;
        uint256 healthFactor;
        uint256 currentLtv;
        uint256 totalDelegated;
        uint256 numDelegateAddresses;
        uint256 maxDelegateAddresses;
    }
    function collateralToken() external view returns (address);
    function debtToken() external view returns (address);
    function ohm() external view returns (address);
    function staking() external view returns (address);
    function accountPosition(address account) external view returns (AccountPosition memory);
    function addCollateral(uint128 amount, address account, DelegationRequest[] calldata requests) external;
    function borrow(uint128 amount, address account, address recipient) external returns (uint128);
    function repay(uint128 amount, address account) external returns (uint128);
    function withdrawCollateral(
        uint128 amount,
        address account,
        address recipient,
        DelegationRequest[] calldata requests
    ) external returns (uint128);
}

/// @dev Uniswap V3 SwapRouter (the original deadline-bearing ABI, not SwapRouter02).
interface IV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256);
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256);
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IReceipt {
    function ownerOf(uint256 id) external view returns (address);
    function burn(uint256 id) external;
}
