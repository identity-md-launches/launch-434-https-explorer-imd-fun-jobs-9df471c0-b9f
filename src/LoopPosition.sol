// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LoopConfig} from "./LoopConfig.sol";
import {
    IFxManager,
    IFxPool,
    ICooler,
    IStaking,
    IV3Router,
    IMorpho,
    IPriceFeed,
    IReceipt
} from "./interfaces/Protocols.sol";

/// @notice One isolated account per receipt. Only its current owner can move funds or add leverage.
contract LoopPosition {
    using SafeERC20 for IERC20;

    struct DepositParams {
        address token;
        uint256 amount;
        uint256 fxBorrow;
        uint128 coolerBorrow;
        uint256 wbtcTopUp;
        uint256 minWbtc;
        uint256 minOhm;
        uint256 minGohm;
        uint256 minLoopWbtc;
        uint256 deadline;
        bytes inputPath;
        bytes ohmPath;
        bytes loopPath;
    }

    struct CloseParams {
        uint256 flashAmount;
        uint256 usdsTopUp;
        uint256 minOhm;
        uint256 minUsds;
        uint256 fxRepayBudget;
        uint256 maxUsdsForFx;
        uint256 maxWbtcForUsds;
        uint256 minOut;
        uint256 deadline;
        address outputToken;
        bytes ohmToUsdsPath;
        bytes usdsToFxPath;
        bytes wbtcToUsdsPath;
        bytes outputPath;
    }

    LoopConfig public immutable config;
    IReceipt public immutable receipt;
    uint256 public immutable receiptId;
    uint256 public fxPositionId;
    /// @notice Historical external WBTC contributions, not NAV or a guaranteed redemption amount.
    uint256 public contributedWbtc;
    bool public closed;
    address public finalOwner;
    uint256 private state;
    bytes32 private pendingHash;
    uint256 private pendingAssets;
    uint256 private flashBalanceBefore;

    error Unauthorized();
    error Busy();
    error InvalidInput();
    error Expired();
    error BadTransfer();
    error Slippage();
    error InvalidPath();
    error UnsafeLtv();
    error StalePrice();
    error DependencyChanged();
    error InvalidCallback();
    error DebtRemaining();

    event Deposited(
        address indexed owner,
        address indexed token,
        uint256 inputAmount,
        uint256 capitalWbtc,
        uint256 fxDebt,
        uint256 coolerDebt
    );
    event Closed(address indexed owner, address indexed outputToken, uint256 outputAmount);
    event CollateralAdded(uint256 amount);
    event DebtRepaid(address indexed token, uint256 amount);

    constructor(address config_, address receipt_, uint256 receiptId_) {
        if (config_.code.length == 0 || receipt_.code.length == 0 || receiptId_ == 0) revert InvalidInput();
        config = LoopConfig(config_);
        receipt = IReceipt(receipt_);
        receiptId = receiptId_;
    }

    modifier onlyOwner() {
        if (closed || msg.sender != receipt.ownerOf(receiptId)) revert Unauthorized();
        _;
    }

    modifier locked() {
        if (state != 0) revert Busy();
        state = 1;
        _;
        state = 0;
    }

    function busy() external view returns (bool) {
        return state != 0;
    }

    /// @notice The conservative Chainlink WBTC/USD value, with 18 decimal places.
    function price() public view returns (uint256) {
        (uint80 round, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IPriceFeed(config.priceFeed()).latestRoundData();
        if (
            answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || answeredInRound < round
                || block.timestamp - updatedAt > config.maxPriceAge()
        ) revert StalePrice();
        return uint256(answer) * 1e10;
    }

    function position()
        external
        view
        returns (uint256 rawWbtc, uint256 fxDebt, uint256 gohmCollateral, uint256 coolerDebt, uint256 fxLtv)
    {
        (rawWbtc, fxDebt) = _fxPosition();
        ICooler.AccountPosition memory cp = ICooler(config.cooler()).accountPosition(address(this));
        gohmCollateral = cp.collateral;
        coolerDebt = cp.currentDebt;
        if (fxDebt != 0) {
            uint256 value = Math.mulDiv(rawWbtc, price(), 1e18);
            fxLtv = value == 0 ? type(uint256).max : Math.mulDiv(fxDebt, 1e18, value, Math.Rounding.Ceil);
        }
    }

    function deposit(DepositParams calldata p) external onlyOwner locked {
        _deadline(p.deadline);
        _dependencies();
        if (
            p.amount == 0 || p.fxBorrow == 0 || p.coolerBorrow == 0 || p.coolerBorrow == type(uint128).max
                || p.minGohm == 0
        ) revert InvalidInput();
        uint256 px = price();
        _pull(p.token, msg.sender, p.amount);
        uint256 capital = _swapIn(p.token, config.wbtc(), p.amount, p.minWbtc, p.inputPath, p.deadline);
        if (p.wbtcTopUp != 0) _pull(config.wbtc(), msg.sender, p.wbtcTopUp);
        // Keep the complete ABI argument block so even noncanonical dynamic offsets are preserved.
        _flashLoan(p.coolerBorrow, abi.encodePacked(capital, px, msg.data[4:]), 4);
        (uint256 collateral, uint256 debt) = _fxPosition();
        uint256 value = Math.mulDiv(collateral, price(), 1e18);
        if (debt > Math.mulDiv(value, 33, 100) || IFxPool(config.pool()).getPositionDebtRatio(fxPositionId) > 0.33e18) {
            revert UnsafeLtv();
        }
        contributedWbtc += capital + p.wbtcTopUp;
        emit Deposited(
            msg.sender,
            p.token,
            p.amount,
            capital + p.wbtcTopUp,
            debt,
            ICooler(config.cooler()).accountPosition(address(this)).currentDebt
        );
    }

    function _enter(DepositParams calldata p, uint256 capital, uint256 px) private {
        address usds = config.usds();
        address cooler = config.cooler();
        // Bridge the later Cooler proceeds so the manager is called only once per transaction.
        uint256 loopWbtc = _swapIn(usds, config.wbtc(), p.coolerBorrow, p.minLoopWbtc, p.loopPath, p.deadline);
        uint256 fxReceived = _openFx(capital, capital + loopWbtc + p.wbtcTopUp, p.fxBorrow, px);
        uint256 ohmReceived = _swapIn(config.fxUSD(), config.ohm(), fxReceived, p.minOhm, p.ohmPath, p.deadline);
        uint256 beforeGohm = _balance(config.gohm());
        _approve(config.ohm(), config.staking(), ohmReceived);
        IStaking(config.staking()).stake(address(this), ohmReceived, false, true);
        _approve(config.ohm(), config.staking(), 0);
        uint256 gohmReceived = _balance(config.gohm()) - beforeGohm;
        if (gohmReceived < p.minGohm) revert Slippage();
        _approve(config.gohm(), cooler, gohmReceived);
        ICooler(cooler).addCollateral(_u128(gohmReceived), address(this), new ICooler.DelegationRequest[](0));
        _approve(config.gohm(), cooler, 0);
        uint256 beforeUsds = _balance(usds);
        ICooler(cooler).borrow(p.coolerBorrow, address(this), address(this));
        // Idle USDS must not conceal a short loan disbursement or fund new leverage.
        if (_balance(usds) - beforeUsds != p.coolerBorrow) revert BadTransfer();
    }

    function _openFx(uint256 capital, uint256 totalCollateral, uint256 borrowAmount, uint256 px)
        private
        returns (uint256 received)
    {
        (uint256 beforeColl, uint256 beforeDebt) = _fxPosition();
        uint256 beforeFx = _balance(config.fxUSD());
        _operate(_signed(totalCollateral), _signed(borrowAmount), totalCollateral, 0);
        (uint256 afterColl, uint256 afterDebt) = _fxPosition();
        // Allocate actual credited collateral (after fees/rounding) pro rata to the initial capital.
        // Reinvestment and the top-up must not increase the 49-50% initial borrowing budget.
        uint256 creditedCapital = Math.mulDiv(afterColl - beforeColl, capital, totalCollateral);
        uint256 addedValue = Math.mulDiv(creditedCapital, px, 1e18);
        uint256 addedDebt = afterDebt - beforeDebt;
        // 49-50% allows quotes to account for protocol share rounding and supply fees.
        if (addedDebt == 0 || addedDebt > addedValue / 2 || addedDebt < Math.mulDiv(addedValue, 49, 100)) {
            revert UnsafeLtv();
        }
        received = _balance(config.fxUSD()) - beforeFx;
    }

    /// @notice Full exit. USDS flash liquidity bridges the two repayments; optional USDS covers losses.
    /// @dev flashAmount=0 uses only the owner's supplied USDS and existing idle balances.
    function close(CloseParams calldata p) external onlyOwner locked returns (uint256 output) {
        _deadline(p.deadline);
        // Cooler governance can migrate its debt token. After external repayment of that
        // new token, the owner must still be able to retrieve the collateral through this exit.
        if (
            ICooler(config.cooler()).debtToken() != config.usds()
                && ICooler(config.cooler()).accountPosition(address(this)).currentDebt != 0
        ) revert DependencyChanged();
        if (p.outputToken.code.length == 0) revert InvalidInput();
        if (p.usdsTopUp != 0) _pull(config.usds(), msg.sender, p.usdsTopUp);
        if (p.flashAmount != 0) {
            _flashLoan(p.flashAmount, msg.data[4:], 2);
        } else {
            _unwind(p);
        }
        (uint256 collateral, uint256 debt) = _fxPosition();
        ICooler.AccountPosition memory cp = ICooler(config.cooler()).accountPosition(address(this));
        if (debt != 0 || collateral != 0 || cp.currentDebt != 0 || cp.collateral != 0) revert DebtRemaining();
        uint256 wbtcBalance = _balance(config.wbtc());
        if (wbtcBalance != 0) {
            output = _swapIn(config.wbtc(), p.outputToken, wbtcBalance, p.minOut, p.outputPath, p.deadline);
        } else if (p.minOut != 0) {
            revert Slippage();
        }
        closed = true;
        finalOwner = msg.sender;
        receipt.burn(receiptId);
        uint256 recipientBefore = IERC20(p.outputToken).balanceOf(msg.sender);
        _sweep(p.outputToken, msg.sender);
        _sweep(config.wbtc(), msg.sender);
        _sweep(config.fxUSD(), msg.sender);
        _sweep(config.ohm(), msg.sender);
        _sweep(config.gohm(), msg.sender);
        _sweep(config.usds(), msg.sender);
        output = IERC20(p.outputToken).balanceOf(msg.sender) - recipientBefore;
        if (output < p.minOut) revert Slippage();
        emit Closed(msg.sender, p.outputToken, output);
    }

    /// @dev States: 1 = owner operation; 2 = exit callback pending; 4 = entry callback pending;
    /// 3 = callback consumed. The hash commits to the complete parameters for the selected operation.
    function _flashLoan(uint256 assets, bytes memory data, uint256 callbackState) private {
        pendingHash = keccak256(data);
        pendingAssets = assets;
        flashBalanceBefore = _balance(config.usds());
        state = callbackState;
        IMorpho(config.morpho()).flashLoan(config.usds(), assets, data);
        if (state != 3) revert InvalidCallback();
        _approve(config.usds(), config.morpho(), 0);
        pendingHash = bytes32(0);
        pendingAssets = 0;
        flashBalanceBefore = 0;
        state = 1;
    }

    /// @dev Morpho Blue callback: no other lender, initiator, token, or uncommitted operation is accepted.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (
            msg.sender != config.morpho() || (state != 2 && state != 4) || assets != pendingAssets
                || keccak256(data) != pendingHash || _balance(config.usds()) < flashBalanceBefore + assets
        ) revert InvalidCallback();
        bool entering = state == 4;
        state = 3;
        if (entering) {
            // Authenticated data = capital | price | original deposit ABI arguments (without selector).
            // All original offsets remain relative to the argument block, which begins 64 bytes in.
            DepositParams calldata p;
            uint256 capital;
            uint256 px;
            assembly ("memory-safe") {
                let args := add(data.offset, 64)
                p := add(args, calldataload(args))
                capital := calldataload(data.offset)
                px := calldataload(add(data.offset, 32))
            }
            _enter(p, capital, px);
            if (_balance(config.usds()) < flashBalanceBefore + assets) revert BadTransfer();
        } else {
            // Exit data is the authenticated original close ABI argument block.
            CloseParams calldata p;
            assembly ("memory-safe") {
                p := add(data.offset, calldataload(data.offset))
            }
            _unwind(p);
            uint256 balance = _balance(config.usds());
            if (balance < assets) {
                _swapOut(config.wbtc(), config.usds(), assets - balance, p.maxWbtcForUsds, p.wbtcToUsdsPath, p.deadline);
            }
        }
        _approve(config.usds(), config.morpho(), assets);
    }

    function _unwind(CloseParams calldata p) private {
        ICooler.AccountPosition memory cp = ICooler(config.cooler()).accountPosition(address(this));
        if (cp.currentDebt != 0) {
            _approve(config.usds(), config.cooler(), cp.currentDebt);
            ICooler(config.cooler()).repay(_u128(cp.currentDebt), address(this));
            _approve(config.usds(), config.cooler(), 0);
        }
        if (cp.collateral != 0) {
            ICooler(config.cooler())
                .withdrawCollateral(
                    _u128(cp.collateral), address(this), address(this), new ICooler.DelegationRequest[](0)
                );
        }
        uint256 gohmBalance = _balance(config.gohm());
        if (gohmBalance != 0) {
            uint256 ohmBefore = _balance(config.ohm());
            _approve(config.gohm(), config.staking(), gohmBalance);
            IStaking(config.staking()).unstake(address(this), gohmBalance, false, false);
            _approve(config.gohm(), config.staking(), 0);
            if (p.minOhm == 0 || _balance(config.ohm()) - ohmBefore < p.minOhm) revert Slippage();
        }
        uint256 ohmBalance = _balance(config.ohm());
        if (ohmBalance != 0) _swapIn(config.ohm(), config.usds(), ohmBalance, p.minUsds, p.ohmToUsdsPath, p.deadline);
        (uint256 collateral, uint256 debt) = _fxPosition();
        if (debt != 0) {
            if (p.fxRepayBudget < debt) revert InvalidInput();
            uint256 fxBalance = _balance(config.fxUSD());
            if (fxBalance < p.fxRepayBudget) {
                _swapOut(
                    config.usds(),
                    config.fxUSD(),
                    p.fxRepayBudget - fxBalance,
                    p.maxUsdsForFx,
                    p.usdsToFxPath,
                    p.deadline
                );
            }
        }
        if (collateral != 0 || debt != 0) {
            _operate(
                collateral == 0 ? int256(0) : type(int256).min,
                debt == 0 ? int256(0) : type(int256).min,
                0,
                p.fxRepayBudget
            );
        }
    }

    /// @notice Risk reduction remains available even when the entry price feed is stale.
    function addCollateral(uint256 amount) external onlyOwner locked {
        if (amount == 0 || fxPositionId == 0) revert InvalidInput();
        _pull(config.wbtc(), msg.sender, amount);
        _operate(_signed(amount), 0, amount, 0);
        contributedWbtc += amount;
        emit CollateralAdded(amount);
    }

    /// @param budget Includes f(x) repayment fees; unused fxUSD stays recoverable by the owner.
    function repayFx(uint256 debtAmount, uint256 budget) external onlyOwner locked {
        if (debtAmount == 0 || budget < debtAmount || fxPositionId == 0) revert InvalidInput();
        _pull(config.fxUSD(), msg.sender, budget);
        _operate(0, -_signed(debtAmount), 0, budget);
        emit DebtRepaid(config.fxUSD(), debtAmount);
    }

    function repayCooler(uint128 amount) external onlyOwner locked {
        if (amount == 0 || ICooler(config.cooler()).debtToken() != config.usds()) revert InvalidInput();
        _pull(config.usds(), msg.sender, amount);
        _approve(config.usds(), config.cooler(), amount);
        uint128 repaid = ICooler(config.cooler()).repay(amount, address(this));
        _approve(config.usds(), config.cooler(), 0);
        emit DebtRepaid(config.usds(), repaid);
    }

    /// @notice Recover idle ERC20 balances, including unsolicited transfers. No access to locked collateral.
    function recover(address token) external locked {
        address owner = closed ? finalOwner : receipt.ownerOf(receiptId);
        if (msg.sender != owner) revert Unauthorized();
        _sweep(token, owner);
    }

    function _operate(int256 collateral, int256 debt, uint256 wbtcApproval, uint256 fxApproval) private {
        uint256 fxBefore = _balance(config.fxUSD());
        _approve(config.wbtc(), config.manager(), wbtcApproval);
        _approve(config.fxUSD(), config.manager(), fxApproval);
        uint256 id = IFxManager(config.manager()).operate(config.pool(), fxPositionId, collateral, debt);
        // f(x) burns directly from this account; ERC20 allowance does not constrain that burn.
        if (debt < 0 && fxBefore - _balance(config.fxUSD()) > fxApproval) revert Slippage();
        if (id == 0 || (fxPositionId != 0 && id != fxPositionId)) revert InvalidInput();
        fxPositionId = id;
        _approve(config.wbtc(), config.manager(), 0);
        _approve(config.fxUSD(), config.manager(), 0);
    }

    function _swapIn(address from, address to, uint256 amount, uint256 minimum, bytes memory path, uint256 deadline)
        private
        returns (uint256 received)
    {
        if (amount == 0 || minimum == 0) revert Slippage();
        if (from == to) {
            if (path.length != 0 || amount < minimum) revert Slippage();
            return amount;
        }
        _path(path, from, to);
        uint256 beforeIn = _balance(from);
        uint256 beforeOut = _balance(to);
        _approve(from, config.router(), amount);
        IV3Router(config.router())
            .exactInput(IV3Router.ExactInputParams(path, address(this), deadline, amount, minimum));
        _approve(from, config.router(), 0);
        received = _balance(to) - beforeOut;
        if (received < minimum || beforeIn - _balance(from) != amount) revert Slippage();
    }

    function _swapOut(address from, address to, uint256 amount, uint256 maximum, bytes memory path, uint256 deadline)
        private
    {
        if (maximum == 0) revert Slippage();
        _path(path, to, from); // Exact-output routes have reversed endpoints and hops.
        uint256 beforeIn = _balance(from);
        uint256 beforeOut = _balance(to);
        _approve(from, config.router(), maximum);
        IV3Router(config.router())
            .exactOutput(IV3Router.ExactOutputParams(path, address(this), deadline, amount, maximum));
        _approve(from, config.router(), 0);
        if (_balance(to) - beforeOut < amount || beforeIn - _balance(from) > maximum) revert Slippage();
    }

    function _path(bytes memory path, address first, address last) private pure {
        if (path.length < 43 || path.length > 250 || (path.length - 20) % 23 != 0) revert InvalidPath();
        address a;
        address b;
        assembly ("memory-safe") {
            a := shr(96, mload(add(path, 32)))
            b := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
        if (a != first || b != last) revert InvalidPath();
    }

    function _pull(address token, address from, uint256 amount) private {
        uint256 beforeBalance = _balance(token);
        IERC20(token).safeTransferFrom(from, address(this), amount);
        if (_balance(token) - beforeBalance != amount) revert BadTransfer();
    }

    function _sweep(address token, address to) private {
        uint256 amount = _balance(token);
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }

    function _balance(address token) private view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function _approve(address token, address spender, uint256 amount) private {
        IERC20(token).forceApprove(spender, amount);
    }

    function _signed(uint256 amount) private pure returns (int256) {
        if (amount > uint256(type(int256).max)) revert InvalidInput();
        return int256(amount);
    }

    function _u128(uint256 amount) private pure returns (uint128) {
        if (amount > type(uint128).max) revert InvalidInput();
        return uint128(amount);
    }

    function _deadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
    }

    function _fxPosition() private view returns (uint256, uint256) {
        if (fxPositionId == 0) return (0, 0);
        return IFxPool(config.pool()).getPosition(fxPositionId);
    }

    function _dependencies() private view {
        if (
            ICooler(config.cooler()).debtToken() != config.usds()
                || IFxManager(config.manager()).getTokenScalingFactor(config.wbtc()) != 1e28
        ) revert DependencyChanged();
        config.validate();
    }
}
