// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WbtcUsdFeed} from "src/WbtcUsdFeed.sol";
import {MockFeed} from "./mocks/Protocols.mock.sol";

/// forge-config: default.fuzz.runs = 1000
contract OraclePropertiesTest is Test {
    MockFeed basis;
    MockFeed btc;
    WbtcUsdFeed composite;

    function setUp() public {
        vm.warp(1_000_000);
        basis = new MockFeed();
        btc = new MockFeed();
        basis.set(1e8, block.timestamp);
        composite = new WbtcUsdFeed(address(basis), address(btc), 2 hours, 1 hours);
    }

    function testFuzzCompositionRoundingMonotonicityAndOldestTimestamp(
        uint128 basisSeed,
        uint128 btcSeed,
        uint256 basisAgeSeed,
        uint256 btcAgeSeed
    ) public {
        uint256 a = bound(basisSeed, 1, 2e8);
        uint256 b = bound(btcSeed, 1e8, 1e14);
        uint256 ta = block.timestamp - bound(basisAgeSeed, 0, 2 hours);
        uint256 tb = block.timestamp - bound(btcAgeSeed, 0, 1 hours);
        basis.set(int256(a), ta);
        btc.set(int256(b), tb);
        (uint80 round, int256 answer, uint256 started, uint256 updated, uint80 answeredRound) =
            composite.latestRoundData();
        // Rational bounds require floor rounding, without using the implementation's mulDiv.
        uint256 product = a * b;
        assertLe(uint256(answer) * 1e8, product);
        assertGt((uint256(answer) + 1) * 1e8, product);
        assertEq(updated, ta < tb ? ta : tb);
        assertEq(started, updated);
        assertGe(answeredRound, round);
        assertEq(composite.decimals(), 8);
        basis.set(int256(a + 1), ta);
        (, int256 increased,,,) = composite.latestRoundData();
        assertGe(increased, answer);
    }

    function testEachComponentAcceptsExactAgeAndRejectsOneSecondOlder() public {
        basis.set(1e8, block.timestamp - 2 hours);
        btc.set(100_000e8, block.timestamp - 1 hours);
        (, int256 answer,, uint256 updated,) = composite.latestRoundData();
        assertEq(answer, 100_000e8);
        assertEq(updated, block.timestamp - 2 hours);
        basis.set(1e8, block.timestamp - 2 hours - 1);
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
        basis.set(1e8, block.timestamp);
        btc.set(100_000e8, block.timestamp - 1 hours - 1);
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
    }

    function testEachComponentRejectsZeroNegativeFutureUnsetAndIncompleteRound() public {
        for (uint256 side; side < 2; ++side) {
            MockFeed target = side == 0 ? basis : btc;
            int256 original = target.answer();
            for (uint256 bad; bad < 5; ++bad) {
                target.set(original, block.timestamp);
                if (bad == 0) target.set(0, block.timestamp);
                if (bad == 1) target.set(-1, block.timestamp);
                if (bad == 2) target.set(original, block.timestamp + 1);
                if (bad == 3) target.set(original, 0);
                if (bad == 4) target.setRound(0);
                vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
                composite.latestRoundData();
                target.set(original, block.timestamp);
                target.setRound(1);
            }
        }
        (, int256 restored,,,) = composite.latestRoundData();
        assertEq(restored, 100_000e8);
    }

    function testEachComponentRejectsMissingCodeAndWrongDecimals() public {
        for (uint256 i; i < 2; ++i) {
            address target = i == 0 ? address(basis) : address(btc);
            vm.mockCall(target, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
            vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
            composite.latestRoundData();
            vm.clearMockedCalls();
            bytes memory code = target.code;
            vm.etch(target, hex"");
            vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
            composite.latestRoundData();
            vm.etch(target, code);
        }
    }

    function testFullPrecisionMultiplicationAndSignedResultBoundary() public {
        basis.set(type(int256).max, block.timestamp);
        btc.set(1e8, block.timestamp);
        (, int256 answer,,,) = composite.latestRoundData();
        assertEq(answer, type(int256).max, "intermediate multiplication must not overflow");
        btc.set(1e8 + 1, block.timestamp);
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
    }

    function testPositiveComponentsCannotPublishRoundedZero() public {
        basis.set(1, block.timestamp);
        btc.set(1, block.timestamp);
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
        btc.set(1e8, block.timestamp);
        (, int256 answer,,,) = composite.latestRoundData();
        assertEq(answer, 1);
    }

    function testConstructorAddressAndAgeBoundaries() public {
        vm.expectRevert("invalid feed");
        new WbtcUsdFeed(address(0), address(btc), 1, 1);
        vm.expectRevert("invalid feed");
        new WbtcUsdFeed(address(basis), address(0), 1, 1);
        vm.expectRevert("invalid feed");
        new WbtcUsdFeed(address(basis), address(basis), 1, 1);
        for (uint256 i; i < 4; ++i) {
            uint256 a = i == 0 ? 0 : i == 1 ? 7 days + 1 : 1;
            uint256 b = i == 2 ? 0 : i == 3 ? 7 days + 1 : 1;
            vm.expectRevert("feed age");
            new WbtcUsdFeed(address(basis), address(btc), a, b);
        }
        WbtcUsdFeed maximumAge = new WbtcUsdFeed(address(basis), address(btc), 7 days, 7 days);
        (, int256 answer,,,) = maximumAge.latestRoundData();
        assertEq(answer, 100_000e8);
    }
}
