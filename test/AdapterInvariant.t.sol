// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FxSwapRouter} from "src/FxSwapRouter.sol";
import {IV3Router} from "src/interfaces/Protocols.sol";
import {MockToken, MockRouter} from "./mocks/Protocols.mock.sol";
import {MockCurve} from "./Adapters.t.sol";

abstract contract AdapterPropertyFixture is Test {
    MockToken internal usdc;
    MockToken internal fx;
    MockToken internal wbtc;
    MockToken internal ohm;
    MockRouter internal router;
    MockCurve internal curve;
    FxSwapRouter internal adapter;

    function _deploy() internal {
        vm.warp(1_000_000);
        usdc = new MockToken("USDC", 6);
        fx = new MockToken("fxUSD", 18);
        wbtc = new MockToken("WBTC", 8);
        ohm = new MockToken("OHM", 9);
        router = new MockRouter();
        curve = new MockCurve(address(usdc), address(fx));
        adapter = new FxSwapRouter(address(router), address(router), address(curve), address(fx), address(usdc));
        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(wbtc), 100_000e18);
        router.setPrice(address(ohm), 20e18);
        usdc.mint(address(curve), 1_000_000_000e6);
        fx.mint(address(curve), 1_000_000_000e18);
        usdc.mint(address(router), 1_000_000_000e6);
        wbtc.mint(address(router), 1_000_000e8);
        ohm.mint(address(router), 1_000_000_000e9);
    }

    function _token(uint256 index) internal view returns (MockToken) {
        if (index == 0) return usdc;
        if (index == 1) return fx;
        if (index == 2) return wbtc;
        return ohm;
    }

    function _path(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }
}

contract AdapterSequenceHandler is AdapterPropertyFixture {
    address[3] public actors = [address(0x101), address(0x202), address(0x303)];
    uint256[4] public donated;
    uint256[4][3] public ledger;
    uint256 public swaps;
    uint256 public initialValue;

    constructor() {
        _deploy();
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 4; ++j) {
                MockToken token = _token(j);
                uint256 amount = 1_000_000 * 10 ** token.decimals();
                token.mint(actors[i], amount);
                ledger[i][j] = amount;
                initialValue += _value(j, amount);
                vm.prank(actors[i]);
                token.approve(address(adapter), type(uint256).max);
            }
        }
    }

    function exactInput(uint256 actorSeed, uint256 recipientSeed, uint256 routeSeed, uint256 amountSeed) public {
        uint256 payer = actorSeed % 3;
        uint256 recipient = recipientSeed % 3;
        (bytes memory path, uint256 from, uint256 to) = _inputRoute(routeSeed);
        uint256 unit = 10 ** _token(from).decimals();
        uint256 cap = from == 2 ? unit : 1000 * unit;
        uint256 amount = bound(amountSeed, unit / 1000, cap);
        uint256 minimum = adapter.quoteExactInput(path, amount);
        assertGt(minimum, 0);
        vm.prank(actors[payer]);
        uint256 output =
            adapter.exactInput(IV3Router.ExactInputParams(path, actors[recipient], block.timestamp, amount, minimum));
        assertGe(output, minimum);
        ledger[payer][from] -= amount;
        ledger[recipient][to] += output;
        ++swaps;
    }

    function exactOutput(
        uint256 actorSeed,
        uint256 recipientSeed,
        uint256 routeSeed,
        uint256 amountSeed,
        uint256 paddingSeed
    ) public {
        uint256 payer = actorSeed % 3;
        uint256 recipient = recipientSeed % 3;
        (bytes memory path, uint256 from, uint256 to) = _outputRoute(routeSeed);
        uint256 unit = 10 ** _token(to).decimals();
        uint256 amount = bound(amountSeed, 1, to == 2 ? unit : 1000 * unit);
        uint256 quote = adapter.quoteExactOutput(path, amount);
        uint256 maximum = quote + bound(paddingSeed, 0, 10 ** _token(from).decimals());
        uint256 curveBefore = fx.balanceOf(address(curve));
        vm.prank(actors[payer]);
        uint256 spent =
            adapter.exactOutput(IV3Router.ExactOutputParams(path, actors[recipient], block.timestamp, amount, maximum));
        assertLe(spent, maximum);
        ledger[payer][from] -= spent;
        ledger[recipient][to] += amount;
        if (to == 1) {
            // Curve's reserve loss independently measures its complete output; any amount
            // above the recipient's request belongs to the payer, even for different wallets.
            uint256 surplus = curveBefore - fx.balanceOf(address(curve)) - amount;
            ledger[payer][to] += surplus;
        }
        ++swaps;
    }

    function donate(uint256 actorSeed, uint256 tokenSeed, uint256 amountSeed) external {
        uint256 actor = actorSeed % 3;
        uint256 index = tokenSeed % 4;
        MockToken token = _token(index);
        uint256 amount = bound(amountSeed, 0, 10 ** token.decimals());
        vm.prank(actors[actor]);
        token.transfer(address(adapter), amount);
        donated[index] += amount;
        ledger[actor][index] -= amount;
    }

    function inverseQuoteError(uint256 seed) external {
        // Approximate Curve inverse quotes vary independently of actual execution prices.
        curve.setQuoteError(bound(seed, 0, 100));
    }

    function rejectedSwap(uint256 actorSeed, bool insufficientMaximum) external {
        address actor = actors[actorSeed % 3];
        bytes memory path = _path(address(fx), 0, address(usdc));
        if (insufficientMaximum) {
            // Exact get_dx avoids classifying an approximate quote's cushion as mandatory.
            curve.setQuoteError(0);
            uint256 minimumInput = adapter.quoteExactOutput(path, 1000e18);
            vm.prank(actor);
            vm.expectRevert(FxSwapRouter.SwapFailed.selector);
            adapter.exactOutput(IV3Router.ExactOutputParams(path, actor, block.timestamp, 1000e18, minimumInput - 1));
        } else {
            vm.prank(actor);
            vm.expectRevert(FxSwapRouter.SwapFailed.selector);
            adapter.exactInput(IV3Router.ExactInputParams(path, actor, block.timestamp - 1, 1000e18, 1));
        }
    }

    function _inputRoute(uint256 seed) internal view returns (bytes memory, uint256, uint256) {
        if (seed % 5 == 0) return (_path(address(fx), 0, address(usdc)), 1, 0);
        if (seed % 5 == 1) return (_path(address(usdc), 0, address(fx)), 0, 1);
        if (seed % 5 == 2) {
            return (abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(ohm)), 1, 3);
        }
        if (seed % 5 == 3) {
            return (abi.encodePacked(address(wbtc), uint24(3000), address(usdc), uint24(0), address(fx)), 2, 1);
        }
        return (_path(address(wbtc), 3000, address(usdc)), 2, 0);
    }

    function _outputRoute(uint256 seed) internal view returns (bytes memory, uint256, uint256) {
        if (seed % 3 == 0) return (_path(address(fx), 0, address(usdc)), 0, 1);
        if (seed % 3 == 1) {
            return (abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(wbtc)), 2, 1);
        }
        return (_path(address(wbtc), 3000, address(usdc)), 0, 2);
    }

    function _value(uint256 index, uint256 amount) internal pure returns (uint256) {
        if (index == 0) return amount * 1e12;
        if (index == 1) return amount;
        if (index == 2) return amount * 1e15;
        return amount * 20e9;
    }

    function assertAccounting() external view {
        uint256 totalValue;
        for (uint256 j; j < 4; ++j) {
            MockToken token = _token(j);
            assertEq(token.balanceOf(address(adapter)), donated[j], "swap consumed or retained unrelated assets");
            assertEq(token.allowance(address(adapter), address(router)), 0);
            assertEq(token.allowance(address(adapter), address(curve)), 0);
            totalValue += _value(j, donated[j]);
            for (uint256 i; i < 3; ++i) {
                assertEq(token.balanceOf(actors[i]), ledger[i][j], "payer/recipient/refund ledger");
                totalValue += _value(j, token.balanceOf(actors[i]));
            }
        }
        assertLe(totalValue, initialValue, "swapping created value");
        assertEq(address(adapter).balance, 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract AdapterInvariantTest is Test {
    AdapterSequenceHandler handler;

    function setUp() public {
        handler = new AdapterSequenceHandler();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.exactInput.selector;
        selectors[1] = handler.exactOutput.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.inverseQuoteError.selector;
        selectors[4] = handler.rejectedSwap.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_swapConservationRefundsAndNoResidualApprovals() public view {
        handler.assertAccounting();
    }

    function testAllRoutesWithSeparatePayerRecipientAndDonatedDust() public {
        for (uint256 i; i < 4; ++i) {
            handler.donate(0, i, 1);
        }
        handler.inverseQuoteError(100);
        for (uint256 i; i < 5; ++i) {
            handler.exactInput(0, 1, i, 1e18);
            handler.assertAccounting();
        }
        for (uint256 i; i < 3; ++i) {
            handler.exactOutput(1, 2, i, 1, type(uint256).max);
            handler.assertAccounting();
        }
        handler.rejectedSwap(0, true);
        handler.assertAccounting();
        assertEq(handler.swaps(), 8);
    }
}
