// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FxSwapRouter} from "../src/FxSwapRouter.sol";
import {WbtcUsdFeed} from "../src/WbtcUsdFeed.sol";
import {IV3Router} from "../src/interfaces/Protocols.sol";
import {MockToken, MockRouter, MockFeed} from "./mocks/Protocols.mock.sol";

contract MockCurve {
    address[2] public coins;
    uint256 public quoteErrorBps;

    function setQuoteError(uint256 bps) external {
        quoteErrorBps = bps;
    }

    constructor(address usdc, address fx) {
        coins = [usdc, fx];
    }

    function get_dy(int128 i, int128 j, uint256 dx) public pure returns (uint256) {
        require(i != j && (i == 0 || i == 1) && (j == 0 || j == 1));
        uint256 gross = i == 0 ? dx * 1e12 : dx / 1e12;
        return gross * 9995 / 10000;
    }

    function get_dx(int128 i, int128 j, uint256 dy) external view returns (uint256) {
        require(i != j);
        uint256 gross = Math.ceilDiv(dy * 10000, 9995);
        uint256 result = i == 0 ? Math.ceilDiv(gross, 1e12) : gross * 1e12;
        return result * (10000 - quoteErrorBps) / 10000;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 minimum, address recipient)
        external
        returns (uint256 dy)
    {
        dy = get_dy(i, j, dx);
        require(dy >= minimum, "curve minimum");
        IERC20(coins[uint128(i)]).transferFrom(msg.sender, address(this), dx);
        IERC20(coins[uint128(j)]).transfer(recipient, dy);
    }
}

contract AdapterTest is Test {
    MockToken fx;
    MockToken usdc;
    MockToken wbtc;
    MockToken ohm;
    MockRouter router;
    MockCurve curve;
    FxSwapRouter adapter;

    function setUp() public {
        vm.warp(100_000);
        fx = new MockToken("fxUSD", 18);
        usdc = new MockToken("USDC", 6);
        wbtc = new MockToken("WBTC", 8);
        ohm = new MockToken("OHM", 9);
        router = new MockRouter();
        curve = new MockCurve(address(usdc), address(fx));
        adapter = new FxSwapRouter(address(router), address(router), address(curve), address(fx), address(usdc));
        router.setPrice(address(usdc), 1e18);
        router.setPrice(address(wbtc), 100_000e18);
        router.setPrice(address(ohm), 20e18);
        fx.mint(address(this), 1_000_000e18);
        usdc.mint(address(this), 1_000_000e6);
        wbtc.mint(address(this), 10e8);
        fx.mint(address(curve), 10_000_000e18);
        usdc.mint(address(curve), 10_000_000e6);
        usdc.mint(address(router), 10_000_000e6);
        ohm.mint(address(router), 1_000_000e9);
        wbtc.mint(address(router), 100e8);
        fx.approve(address(adapter), type(uint256).max);
        usdc.approve(address(adapter), type(uint256).max);
        wbtc.approve(address(adapter), type(uint256).max);
    }

    function path(address a, uint24 fee, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, b);
    }

    function testCurveThenV3ExactInput() public {
        bytes memory route = abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(ohm));
        uint256 quote = adapter.quoteExactInput(route, 10_000e18);
        uint256 out =
            adapter.exactInput(IV3Router.ExactInputParams(route, address(this), block.timestamp, 10_000e18, quote));
        assertEq(out, quote);
        assertEq(ohm.balanceOf(address(this)), quote);
        _empty();
    }

    function testV3ThenCurveExactInput() public {
        bytes memory route = abi.encodePacked(address(wbtc), uint24(3000), address(usdc), uint24(0), address(fx));
        uint256 quote = adapter.quoteExactInput(route, 1e8);
        uint256 beforeFx = fx.balanceOf(address(this));
        adapter.exactInput(IV3Router.ExactInputParams(route, address(this), block.timestamp, 1e8, quote));
        assertEq(fx.balanceOf(address(this)) - beforeFx, quote);
        _empty();
    }

    function testBoundedV3AndCurveExactOutputRefundsUnspentInput() public {
        bytes memory reverse = abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(wbtc));
        uint256 quote = adapter.quoteExactOutput(reverse, 50_000e18);
        uint256 beforeWbtc = wbtc.balanceOf(address(this));
        uint256 beforeFx = fx.balanceOf(address(this));
        uint256 spent =
            adapter.exactOutput(IV3Router.ExactOutputParams(reverse, address(this), block.timestamp, 50_000e18, 1e8));
        assertEq(spent, quote);
        assertEq(beforeWbtc - wbtc.balanceOf(address(this)), spent);
        assertGe(fx.balanceOf(address(this)) - beforeFx, 50_000e18);
        _empty();
    }

    function testCurveOnlyBothDirections() public {
        bytes memory route = path(address(fx), 0, address(usdc));
        adapter.exactInput(IV3Router.ExactInputParams(route, address(this), block.timestamp, 1000e18, 999e6));
        uint256 quote = adapter.quoteExactOutput(route, 1000e18);
        adapter.exactOutput(IV3Router.ExactOutputParams(route, address(this), block.timestamp, 1000e18, quote));
        _empty();
    }

    function testCurveApproximateInverseIsVerifiedBeforeSwapping() public {
        curve.setQuoteError(30);
        bytes memory reverse = abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(wbtc));
        uint256 q = adapter.quoteExactOutput(reverse, 100_000e18);
        uint256 beforeFx = fx.balanceOf(address(this));
        adapter.exactOutput(IV3Router.ExactOutputParams(reverse, address(this), block.timestamp, 100_000e18, q));
        assertGe(fx.balanceOf(address(this)) - beforeFx, 100_000e18);
        _empty();
    }

    function testPureV3Passthrough() public {
        bytes memory route = path(address(wbtc), 3000, address(usdc));
        adapter.exactInput(IV3Router.ExactInputParams(route, address(this), block.timestamp, 1e8, 100_000e6));
        adapter.exactOutput(IV3Router.ExactOutputParams(route, address(this), block.timestamp, 1e8, 100_000e6));
        _empty();
    }

    function testMalformedRoutesAndWrongCurveEndpoints() public {
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.quoteExactInput(path(address(fx), 3000, address(usdc)), 1e18);
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.quoteExactInput(path(address(fx), 0, address(ohm)), 1e18);
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.quoteExactOutput(path(address(usdc), 0, address(fx)), 1e6);
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.quoteExactInput(path(address(ohm), 0, address(usdc)), 1e9);
    }

    function testSlippageAndAllowanceRevocation() public {
        bytes memory route = path(address(fx), 0, address(usdc));
        vm.expectRevert("curve minimum");
        adapter.exactInput(IV3Router.ExactInputParams(route, address(this), block.timestamp, 1000e18, 1001e6));
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactOutput(IV3Router.ExactOutputParams(route, address(this), block.timestamp, 1000e18, 999e6));
        _empty();
    }

    function testAdapterDonationsCannotBeTakenBySwap() public {
        usdc.mint(address(adapter), 1234);
        fx.mint(address(adapter), 999);
        bytes memory route = path(address(fx), 0, address(usdc));
        uint256 q = adapter.quoteExactInput(route, 1000e18);
        uint256 beforeUsdc = usdc.balanceOf(address(this));
        adapter.exactInput(IV3Router.ExactInputParams(route, address(this), block.timestamp, 1000e18, q));
        assertEq(usdc.balanceOf(address(this)) - beforeUsdc, q);
        assertEq(usdc.balanceOf(address(adapter)), 1234);
        assertEq(fx.balanceOf(address(adapter)), 999);
    }

    function testFuzzExactOutputBounds(uint96 seed) public {
        uint256 amount = bound(seed, 1e12, 100_000e18);
        bytes memory reverse = abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(wbtc));
        uint256 q = adapter.quoteExactOutput(reverse, amount);
        uint256 beforeWbtc = wbtc.balanceOf(address(this));
        uint256 beforeFx = fx.balanceOf(address(this));
        adapter.exactOutput(IV3Router.ExactOutputParams(reverse, address(this), block.timestamp, amount, q));
        assertEq(beforeWbtc - wbtc.balanceOf(address(this)), q);
        assertGe(fx.balanceOf(address(this)) - beforeFx, amount);
        _empty();
    }

    function testRouterRuntimeWithinLaunchConstraints() public view {
        bytes memory code = address(adapter).code;
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function _empty() internal view {
        assertEq(fx.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(wbtc.balanceOf(address(adapter)), 0);
        assertEq(fx.allowance(address(adapter), address(curve)), 0);
        assertEq(usdc.allowance(address(adapter), address(curve)), 0);
        assertEq(wbtc.allowance(address(adapter), address(router)), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
    }
}

contract CompositeFeedTest is Test {
    function testCompositePriceIncludesWrappedBitcoinBasisAndFreshness() public {
        vm.warp(100_000);
        MockFeed basis = new MockFeed();
        MockFeed btc = new MockFeed();
        basis.set(0.98e8, block.timestamp - 7200);
        btc.set(100_000e8, block.timestamp);
        WbtcUsdFeed composite = new WbtcUsdFeed(address(basis), address(btc), 90000, 7200);
        (, int256 answer,, uint256 timestamp,) = composite.latestRoundData();
        assertEq(answer, 98_000e8);
        assertEq(timestamp, block.timestamp - 7200);
        bytes memory code = address(composite).code;
        assertLe(code.length, 24576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
        btc.set(100_000e8, block.timestamp - 7201);
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
        btc.set(100_000e8, block.timestamp);
        basis.set(1e8, block.timestamp - 90001);
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
        basis.set(-1, block.timestamp);
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
    }
}
