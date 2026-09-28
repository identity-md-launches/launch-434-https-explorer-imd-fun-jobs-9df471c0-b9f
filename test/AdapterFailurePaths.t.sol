// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AdapterPropertyFixture} from "./AdapterInvariant.t.sol";
import {FxSwapRouter} from "src/FxSwapRouter.sol";
import {IV3Router} from "src/interfaces/Protocols.sol";
import {MockToken} from "./mocks/Protocols.mock.sol";

contract AdapterReentryProbe {
    bool public succeeded;
    bytes public result;

    function attack(address target, bytes calldata data) external {
        (succeeded, result) = target.call(data);
    }
}

contract AdapterFailurePathsTest is AdapterPropertyFixture {
    function setUp() public {
        _deploy();
        for (uint256 i; i < 4; ++i) {
            MockToken token = _token(i);
            token.mint(address(this), 1_000_000 * 10 ** token.decimals());
            token.approve(address(adapter), type(uint256).max);
        }
    }

    function _input() internal view returns (IV3Router.ExactInputParams memory) {
        return IV3Router.ExactInputParams(
            _path(address(wbtc), 3000, address(usdc)), address(this), block.timestamp, 1e8, 100_000e6
        );
    }

    function _output() internal view returns (IV3Router.ExactOutputParams memory) {
        return IV3Router.ExactOutputParams(
            _path(address(wbtc), 3000, address(usdc)), address(this), block.timestamp, 1e8, 100_000e6
        );
    }

    function _snapshot() internal view returns (bytes32 state) {
        for (uint256 i; i < 4; ++i) {
            MockToken token = _token(i);
            state = keccak256(
                abi.encode(
                    state,
                    token.totalSupply(),
                    token.balanceOf(address(this)),
                    token.balanceOf(address(adapter)),
                    token.balanceOf(address(curve)),
                    token.balanceOf(address(router)),
                    token.allowance(address(this), address(adapter)),
                    token.allowance(address(adapter), address(curve)),
                    token.allowance(address(adapter), address(router))
                )
            );
        }
    }

    function testZeroInputMinimumAndExactOutputLimitsAreRejected() public {
        bytes32 beforeState = _snapshot();
        IV3Router.ExactInputParams memory p = _input();
        p.amountIn = 0;
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactInput(p);
        p = _input();
        p.amountOutMinimum = 0;
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactInput(p);
        IV3Router.ExactOutputParams memory q = _output();
        q.amountOut = 0;
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.exactOutput(q);
        q = _output();
        q.amountInMaximum = 0;
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.exactOutput(q);
        assertEq(_snapshot(), beforeState);
    }

    function testZeroAndSelfRecipientsAreRejectedInBothModes() public {
        bytes32 beforeState = _snapshot();
        for (uint256 i; i < 2; ++i) {
            IV3Router.ExactInputParams memory p = _input();
            IV3Router.ExactOutputParams memory q = _output();
            p.recipient = i == 0 ? address(0) : address(adapter);
            q.recipient = p.recipient;
            vm.expectRevert(FxSwapRouter.SwapFailed.selector);
            adapter.exactInput(p);
            vm.expectRevert(FxSwapRouter.SwapFailed.selector);
            adapter.exactOutput(q);
            assertEq(_snapshot(), beforeState);
        }
    }

    function testNativeValueAndExpiredDeadlinesAreRejected() public {
        vm.deal(address(this), 2);
        bytes32 beforeState = _snapshot();
        IV3Router.ExactInputParams memory p = _input();
        IV3Router.ExactOutputParams memory q = _output();
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactInput{value: 1}(p);
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactOutput{value: 1}(q);
        --p.deadline;
        --q.deadline;
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactInput(p);
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactOutput(q);
        assertEq(_snapshot(), beforeState);
        assertEq(address(adapter).balance, 0);
        assertEq(address(this).balance, 2);
        assertEq(adapter.exactInput(_input()), 100_000e6);
    }

    function _assertInvalidRoute(bytes memory path) internal {
        bytes32 beforeState = _snapshot();
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.quoteExactInput(path, 1);
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.quoteExactOutput(path, 1);
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.exactInput(IV3Router.ExactInputParams(path, address(this), block.timestamp, 1, 1));
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.exactOutput(IV3Router.ExactOutputParams(path, address(this), block.timestamp, 1, 1));
        assertEq(_snapshot(), beforeState);
    }

    function testMalformedLengthSameEndpointsAndInteriorFxHopAreRejected() public {
        _assertInvalidRoute(hex"");
        _assertInvalidRoute(new bytes(42));
        _assertInvalidRoute(new bytes(44));
        _assertInvalidRoute(new bytes(251));
        _assertInvalidRoute(new bytes(273));
        _assertInvalidRoute(_path(address(wbtc), 3000, address(wbtc)));
        _assertInvalidRoute(_path(address(fx), 500, address(usdc)));
        _assertInvalidRoute(_path(address(wbtc), 0, address(usdc)));
        _assertInvalidRoute(_path(address(fx), 0, address(wbtc)));
        _assertInvalidRoute(
            abi.encodePacked(
                address(wbtc), uint24(3000), address(usdc), uint24(0), address(fx), uint24(0), address(usdc)
            )
        );
    }

    function testExactOutputCannotUseFxAsInput() public {
        bytes memory reverse = _path(address(usdc), 0, address(fx));
        bytes32 beforeState = _snapshot();
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.quoteExactOutput(reverse, 1e6);
        vm.expectRevert(FxSwapRouter.InvalidRoute.selector);
        adapter.exactOutput(IV3Router.ExactOutputParams(reverse, address(this), block.timestamp, 1e6, 2e18));
        assertEq(_snapshot(), beforeState);
    }

    function testLyingRouterCannotUseDonationsToMaskMissingOutput() public {
        wbtc.transfer(address(adapter), 2e8);
        usdc.transfer(address(adapter), 200_000e6);
        router.setLie(true);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactInput(_input());
        assertEq(_snapshot(), beforeState);
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactOutput(_output());
        assertEq(_snapshot(), beforeState);
        router.setLie(false);
        assertEq(adapter.exactInput(_input()), 100_000e6);
        assertEq(wbtc.balanceOf(address(adapter)), 2e8);
        assertEq(usdc.balanceOf(address(adapter)), 200_000e6);
    }

    function testTaxedInputPullRollsBackIncludingBurnAndApproval() public {
        wbtc.setTax(100);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactInput(_input());
        assertEq(_snapshot(), beforeState);
        usdc.setTax(100);
        beforeState = _snapshot();
        vm.expectRevert(FxSwapRouter.SwapFailed.selector);
        adapter.exactOutput(_output());
        assertEq(_snapshot(), beforeState);
    }

    function testOneUnitTooLittleInputOrTooMuchOutputRollsBack() public {
        bytes32 beforeState = _snapshot();
        IV3Router.ExactInputParams memory p = _input();
        ++p.amountOutMinimum;
        vm.expectRevert("minOut");
        adapter.exactInput(p);
        IV3Router.ExactOutputParams memory q = _output();
        --q.amountInMaximum;
        vm.expectRevert("maxIn");
        adapter.exactOutput(q);
        assertEq(_snapshot(), beforeState);
    }

    function testReentryDuringBothSwapModesHitsLockAndOuterSwapCompletes() public {
        AdapterReentryProbe probe = new AdapterReentryProbe();
        IV3Router.ExactInputParams memory p = _input();
        router.setHook(
            address(probe), abi.encodeCall(probe.attack, (address(adapter), abi.encodeCall(adapter.exactInput, (p))))
        );
        assertEq(adapter.exactInput(p), 100_000e6);
        assertFalse(probe.succeeded());
        assertEq(probe.result(), abi.encodeWithSelector(FxSwapRouter.SwapFailed.selector));
        IV3Router.ExactOutputParams memory q = _output();
        router.setHook(
            address(probe), abi.encodeCall(probe.attack, (address(adapter), abi.encodeCall(adapter.exactOutput, (q))))
        );
        assertEq(adapter.exactOutput(q), 100_000e6);
        assertFalse(probe.succeeded());
        assertEq(probe.result(), abi.encodeWithSelector(FxSwapRouter.SwapFailed.selector));
        for (uint256 i; i < 4; ++i) {
            assertEq(_token(i).balanceOf(address(adapter)), 0);
            assertEq(_token(i).allowance(address(adapter), address(router)), 0);
        }
    }

    function testMissingDependenciesAreCheckedForQuotesAndSwaps() public {
        vm.etch(address(router), hex"");
        bytes memory path = _path(address(fx), 0, address(usdc));
        bytes32 beforeState = _snapshot();
        vm.expectRevert("missing dependency");
        adapter.quoteExactInput(path, 1e18);
        vm.expectRevert("missing dependency");
        adapter.exactInput(IV3Router.ExactInputParams(path, address(this), block.timestamp, 1e18, 1));
        assertEq(_snapshot(), beforeState);
    }
}
