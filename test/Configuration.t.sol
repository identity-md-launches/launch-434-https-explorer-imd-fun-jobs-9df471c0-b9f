// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoopFixture} from "./Loop.t.sol";
import {LoopConfig} from "../src/LoopConfig.sol";
import {LoopPosition} from "../src/LoopPosition.sol";
import {FxSwapRouter} from "../src/FxSwapRouter.sol";
import {WbtcUsdFeed} from "../src/WbtcUsdFeed.sol";
import {MockFeed} from "./mocks/Protocols.mock.sol";
import {MockCurve} from "./Adapters.t.sol";

contract ConfigurationTest is LoopFixture {
    function testValidRuntimeBindings() public view {
        config.validate();
    }

    function testChangedTokenDecimalsRejectedBeforeAcceptingFunds() public {
        vm.mockCall(address(wbtc), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        uint256 balance = wbtc.balanceOf(address(this));
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        account.deposit(depositParams());
        assertEq(wbtc.balanceOf(address(this)), balance);
        assertEq(account.fxPositionId(), 0);
        assertEq(cooler.debt(address(account)), 0);
    }

    function testChangedPoolBindingRejectedBeforeAcceptingFunds() public {
        vm.mockCall(address(pool), abi.encodeWithSignature("collateralToken()"), abi.encode(address(fx)));
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        account.deposit(depositParams());
        assertEq(account.fxPositionId(), 0);
    }

    function testChangedLtvRangeRejectedBeforeAcceptingFunds() public {
        vm.mockCall(address(pool), abi.encodeWithSignature("getDebtRatioRange()"), abi.encode(0.4e18, 0.85e18));
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        account.deposit(depositParams());
    }

    function testMissingRouterCodeRejectedBeforeAcceptingFunds() public {
        vm.etch(address(router), hex"");
        vm.expectRevert(LoopConfig.InvalidConfiguration.selector);
        account.deposit(depositParams());
    }

    function testRouterRejectsWrongCurveBindingAtUse() public {
        MockCurve wrongCurve = new MockCurve(address(fx), address(input));
        FxSwapRouter adapter =
            new FxSwapRouter(address(router), address(router), address(wrongCurve), address(fx), address(input));
        vm.expectRevert("wrong Curve pool");
        adapter.quoteExactInput(abi.encodePacked(address(fx), uint24(0), address(input)), 1e18);
    }

    function testFeedRejectsUnexpectedDecimalsAtRead() public {
        MockFeed basis = new MockFeed();
        WbtcUsdFeed composite = new WbtcUsdFeed(address(basis), address(feed), 1 hours, 1 hours);
        vm.mockCall(address(basis), abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.expectRevert(WbtcUsdFeed.InvalidPrice.selector);
        composite.latestRoundData();
    }
}
