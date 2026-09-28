// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IV3Router} from "./interfaces/Protocols.sol";

interface ICurveFxPool {
    function coins(uint256 index) external view returns (address);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function get_dx(int128 i, int128 j, uint256 dy) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 minDy, address receiver) external returns (uint256);
}

interface IV3Quoter {
    function quoteExactInput(bytes memory path, uint256 amount) external returns (uint256);
    function quoteExactOutput(bytes memory path, uint256 amount) external returns (uint256);
}

/// @notice Fixed Curve fxUSD/USDC bridge plus Uniswap V3 routes, using the V3 router ABI.
/// A zero-fee hop denotes Curve and is allowed only at an fxUSD endpoint. No arbitrary calls.
contract FxSwapRouter is IV3Router {
    using SafeERC20 for IERC20;
    address public immutable v3Router;
    address public immutable v3Quoter;
    address public immutable curve;
    address public immutable fxUSD;
    address public immutable usdc;
    bool private entered;
    error InvalidRoute();
    error SwapFailed();

    constructor(address router_, address quoter_, address curve_, address fxUSD_, address usdc_) {
        require(router_ != address(0) && quoter_ != address(0) && curve_ != address(0), "missing dependency");
        require(fxUSD_ != address(0) && usdc_ != address(0) && fxUSD_ != usdc_, "wrong Curve pool");
        v3Router = router_;
        v3Quoter = quoter_;
        curve = curve_;
        fxUSD = fxUSD_;
        usdc = usdc_;
    }

    /// @notice Runtime preflight, also enforced on every quote and swap.
    function validate() public view {
        require(v3Router.code.length != 0 && v3Quoter.code.length != 0 && curve.code.length != 0, "missing dependency");
        require(ICurveFxPool(curve).coins(0) == usdc && ICurveFxPool(curve).coins(1) == fxUSD, "wrong Curve pool");
    }

    modifier lock() {
        if (entered) revert SwapFailed();
        entered = true;
        _;
        entered = false;
    }

    function exactInput(ExactInputParams calldata p) external payable lock returns (uint256 output) {
        _check(p.path, p.deadline, p.recipient);
        (address from, address to) = _ends(p.path);
        if (p.amountIn == 0 || p.amountOutMinimum == 0) revert SwapFailed();
        _pull(from, p.amountIn);
        if (from == fxUSD) {
            _curveHop(p.path, true);
            uint256 stable = _curve(1, 0, p.amountIn, p.path.length == 43 ? p.amountOutMinimum : 1);
            output = p.path.length == 43
                ? stable
                : _v3In(_slice(p.path, 23, p.path.length), stable, p.amountOutMinimum, p.deadline);
        } else if (to == fxUSD) {
            _curveHop(p.path, false);
            uint256 stable = p.path.length == 43
                ? p.amountIn
                : _v3In(_slice(p.path, 0, p.path.length - 23), p.amountIn, 1, p.deadline);
            output = _curve(0, 1, stable, p.amountOutMinimum);
        } else {
            output = _v3In(p.path, p.amountIn, p.amountOutMinimum, p.deadline);
        }
        _pay(to, p.recipient, output, p.amountOutMinimum);
    }

    function exactOutput(ExactOutputParams calldata p) external payable lock returns (uint256 spent) {
        _check(p.path, p.deadline, p.recipient);
        (address to, address from) = _ends(p.path);
        if (from == fxUSD || p.amountOut == 0 || p.amountInMaximum == 0) revert InvalidRoute();
        _pull(from, p.amountInMaximum);
        if (to == fxUSD) {
            _curveHop(p.path, true); // reversed path starts fxUSD,0,USDC
            uint256 stable = _curveInput(p.amountOut);
            if (p.path.length == 43) {
                spent = stable;
                if (spent > p.amountInMaximum) revert SwapFailed();
            } else {
                spent = _v3Out(_slice(p.path, 23, p.path.length), stable, p.amountInMaximum, p.deadline);
            }
            uint256 received = _curve(0, 1, stable, p.amountOut);
            _pay(to, p.recipient, p.amountOut, p.amountOut);
            // Rounding surplus belongs to the payer; the requested recipient gets exact output.
            if (received > p.amountOut) IERC20(to).safeTransfer(msg.sender, received - p.amountOut);
        } else {
            spent = _v3Out(p.path, p.amountOut, p.amountInMaximum, p.deadline);
            _pay(to, p.recipient, p.amountOut, p.amountOut);
        }
        if (spent > p.amountInMaximum) revert SwapFailed();
        if (spent < p.amountInMaximum) IERC20(from).safeTransfer(msg.sender, p.amountInMaximum - spent);
    }

    function quoteExactInput(bytes calldata path, uint256 amount) external returns (uint256) {
        _shape(path);
        (address from, address to) = _ends(path);
        if (from == fxUSD) {
            _curveHop(path, true);
            uint256 stable = ICurveFxPool(curve).get_dy(1, 0, amount);
            return
                path.length == 43 ? stable : IV3Quoter(v3Quoter).quoteExactInput(_slice(path, 23, path.length), stable);
        }
        if (to == fxUSD) {
            _curveHop(path, false);
            uint256 stable = path.length == 43
                ? amount
                : IV3Quoter(v3Quoter).quoteExactInput(_slice(path, 0, path.length - 23), amount);
            return ICurveFxPool(curve).get_dy(0, 1, stable);
        }
        return IV3Quoter(v3Quoter).quoteExactInput(path, amount);
    }

    function quoteExactOutput(bytes calldata path, uint256 amount) external returns (uint256) {
        _shape(path);
        (address to, address from) = _ends(path);
        if (from == fxUSD) revert InvalidRoute();
        if (to == fxUSD) {
            _curveHop(path, true);
            uint256 stable = _curveInput(amount);
            return
                path.length == 43 ? stable : IV3Quoter(v3Quoter).quoteExactOutput(_slice(path, 23, path.length), stable);
        }
        return IV3Quoter(v3Quoter).quoteExactOutput(path, amount);
    }

    function _v3In(bytes memory path, uint256 amount, uint256 minimum, uint256 deadline)
        private
        returns (uint256 output)
    {
        (address from, address to) = _ends(path);
        uint256 beforeOut = _balance(to);
        uint256 beforeIn = _balance(from);
        IERC20(from).forceApprove(v3Router, amount);
        IV3Router(v3Router).exactInput(ExactInputParams(path, address(this), deadline, amount, minimum));
        IERC20(from).forceApprove(v3Router, 0);
        output = _balance(to) - beforeOut;
        if (output < minimum || beforeIn - _balance(from) != amount) revert SwapFailed();
    }

    function _v3Out(bytes memory path, uint256 amount, uint256 maximum, uint256 deadline)
        private
        returns (uint256 spent)
    {
        (address to, address from) = _ends(path);
        uint256 beforeOut = _balance(to);
        uint256 beforeIn = _balance(from);
        IERC20(from).forceApprove(v3Router, maximum);
        IV3Router(v3Router).exactOutput(ExactOutputParams(path, address(this), deadline, amount, maximum));
        IERC20(from).forceApprove(v3Router, 0);
        spent = beforeIn - _balance(from);
        if (_balance(to) - beforeOut != amount || spent > maximum) revert SwapFailed();
    }

    function _curve(int128 i, int128 j, uint256 amount, uint256 minimum) private returns (uint256 received) {
        address from = i == 0 ? usdc : fxUSD;
        address to = j == 0 ? usdc : fxUSD;
        uint256 beforeIn = _balance(from);
        uint256 beforeOut = _balance(to);
        IERC20(from).forceApprove(curve, amount);
        ICurveFxPool(curve).exchange(i, j, amount, minimum, address(this));
        IERC20(from).forceApprove(curve, 0);
        received = _balance(to) - beforeOut;
        if (beforeIn - _balance(from) != amount || received < minimum) revert SwapFailed();
    }

    /// @dev Curve NG get_dx is approximate under dynamic fees. Validate against get_dy,
    /// bracket upward, then refine a known-sufficient upper bound. Both quote and swap use this.
    function _curveInput(uint256 output) private view returns (uint256 high) {
        high = ICurveFxPool(curve).get_dx(0, 1, output);
        if (ICurveFxPool(curve).get_dy(0, 1, high) >= output) return high;
        uint256 low = high;
        uint256 step = Math.max(1, high / 1000);
        bool sufficient;
        for (uint256 i; i < 16; ++i) {
            high += step;
            if (ICurveFxPool(curve).get_dy(0, 1, high) >= output) {
                sufficient = true;
                break;
            }
            low = high;
            step *= 2;
        }
        if (!sufficient) revert SwapFailed();
        for (uint256 i; i < 16 && high - low > 1; ++i) {
            uint256 mid = low + (high - low) / 2;
            if (ICurveFxPool(curve).get_dy(0, 1, mid) >= output) high = mid;
            else low = mid;
        }
    }

    function _pull(address t, uint256 amount) private {
        uint256 beforeIn = _balance(t);
        IERC20(t).safeTransferFrom(msg.sender, address(this), amount);
        if (_balance(t) - beforeIn != amount) revert SwapFailed();
    }

    function _pay(address t, address to, uint256 amount, uint256 minimum) private {
        uint256 beforeOut = IERC20(t).balanceOf(to);
        IERC20(t).safeTransfer(to, amount);
        if (IERC20(t).balanceOf(to) - beforeOut < minimum) revert SwapFailed();
    }

    function _balance(address t) private view returns (uint256) {
        return IERC20(t).balanceOf(address(this));
    }

    function _check(bytes memory path, uint256 deadline, address recipient) private view {
        if (msg.value != 0 || block.timestamp > deadline || recipient == address(0) || recipient == address(this)) {
            revert SwapFailed();
        }
        _shape(path);
    }

    function _shape(bytes memory path) private view {
        validate();
        if (path.length < 43 || path.length > 250 || (path.length - 20) % 23 != 0) revert InvalidRoute();
        (address from, address to) = _ends(path);
        if (from == to) revert InvalidRoute();
        for (uint256 offset; offset < path.length - 20; offset += 23) {
            address a;
            address b;
            uint24 fee;
            assembly ("memory-safe") {
                a := shr(96, mload(add(add(path, 32), offset)))
                fee := shr(232, mload(add(add(path, 52), offset)))
                b := shr(96, mload(add(add(path, 55), offset)))
            }
            if (a == fxUSD || b == fxUSD) {
                if (
                    fee != 0
                        || !((offset == 0 && a == fxUSD && b == usdc)
                            || (offset == path.length - 43 && a == usdc && b == fxUSD))
                ) revert InvalidRoute();
            } else if (fee == 0) {
                revert InvalidRoute();
            }
        }
    }

    function _curveHop(bytes memory path, bool first) private view {
        uint256 start = first ? 0 : path.length - 43;
        address a;
        address b;
        uint24 fee;
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(path, 32), start)))
            fee := shr(232, mload(add(add(path, 52), start)))
            b := shr(96, mload(add(add(path, 55), start)))
        }
        if (fee != 0 || (first ? a != fxUSD || b != usdc : a != usdc || b != fxUSD)) revert InvalidRoute();
    }

    function _ends(bytes memory path) private pure returns (address a, address b) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(path, 32)))
            b := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
    }

    function _slice(bytes memory input, uint256 start, uint256 end) private pure returns (bytes memory result) {
        result = new bytes(end - start);
        for (uint256 i; i < result.length; ++i) {
            result[i] = input[start + i];
        }
    }
}
