// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoopFixture} from "./Loop.t.sol";
import {LoopPosition} from "src/LoopPosition.sol";
import {LoopReceipt} from "src/LoopReceipt.sol";
import {LoopAccountDeployer} from "src/LoopAccountDeployer.sol";
import {IERC721Errors, IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract RejectingReceiptReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        revert("receipt refused");
    }
}

contract LoopFailurePathsTest is LoopFixture {
    function _snapshot() internal view returns (bytes32) {
        bytes32 debts = keccak256(
            abi.encode(
                pool.collateral(account.fxPositionId()),
                pool.debt(account.fxPositionId()),
                cooler.collateral(address(account)),
                cooler.debt(address(account)),
                account.fxPositionId(),
                account.contributedWbtc(),
                account.closed(),
                account.busy()
            )
        );
        bytes32 custody = keccak256(
            abi.encode(
                wbtc.balanceOf(address(pool)),
                gohm.balanceOf(address(cooler)),
                usds.balanceOf(address(cooler)),
                usds.balanceOf(address(morpho)),
                ohm.balanceOf(address(staking)),
                wbtc.balanceOf(address(router)),
                usds.balanceOf(address(router)),
                fx.balanceOf(address(router))
            )
        );
        return keccak256(
            abi.encode(
                debts,
                custody,
                receipt.ownerOf(id),
                receipt.getApproved(id),
                wbtc.balanceOf(address(this)),
                fx.balanceOf(address(this)),
                usds.balanceOf(address(this)),
                wbtc.balanceOf(address(account)),
                fx.balanceOf(address(account)),
                usds.balanceOf(address(account)),
                ohm.balanceOf(address(account)),
                gohm.balanceOf(address(account)),
                wbtc.allowance(address(account), address(manager)),
                fx.allowance(address(account), address(manager)),
                usds.allowance(address(account), address(morpho)),
                usds.allowance(address(account), address(cooler))
            )
        );
    }

    function testEveryInvalidDepositScalarRollsBackAnExistingPosition() public {
        _open();
        bytes32 beforeState = _snapshot();
        for (uint256 i; i < 5; ++i) {
            LoopPosition.DepositParams memory p = depositParams();
            if (i == 0) p.amount = 0;
            if (i == 1) p.fxBorrow = 0;
            if (i == 2) p.coolerBorrow = 0;
            if (i == 3) p.coolerBorrow = type(uint128).max;
            if (i == 4) p.minGohm = 0;
            vm.expectRevert(LoopPosition.InvalidInput.selector);
            account.deposit(p);
            assertEq(_snapshot(), beforeState);
        }
    }

    function testZeroSwapMinimumAtEachEntryLegIsAtomic() public {
        bytes32 beforeState = _snapshot();
        for (uint256 i; i < 3; ++i) {
            LoopPosition.DepositParams memory p = depositParams();
            if (i == 0) p.minWbtc = 0;
            if (i == 1) p.minLoopWbtc = 0;
            if (i == 2) p.minOhm = 0;
            vm.expectRevert(LoopPosition.Slippage.selector);
            account.deposit(p);
            assertEq(_snapshot(), beforeState);
        }
        // A previous failed callback must not poison the operation lock.
        _open();
        assertFalse(account.busy());
    }

    function testExactDeadlineSucceedsAndOneSecondLateCloseIsAtomic() public {
        _open();
        LoopPosition.CloseParams memory p = closeParams();
        bytes32 beforeState = _snapshot();
        vm.warp(block.timestamp + 1);
        vm.expectRevert(LoopPosition.Expired.selector);
        account.close(p);
        assertEq(_snapshot(), beforeState);
        p.deadline = block.timestamp;
        account.close(p);
        assertTrue(account.closed());
    }

    function testMissingInputAllowanceCannotUseIdleFunds() public {
        wbtc.mint(address(account), 2e8);
        wbtc.approve(address(account), 0);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(account), 0, 1e8)
        );
        account.deposit(depositParams());
        assertEq(_snapshot(), beforeState);
    }

    function testMalformedRoutesAtEachEntryLegRollBack() public {
        bytes32 beforeState = _snapshot();
        LoopPosition.DepositParams memory p = depositParams();
        p.inputPath = route(address(wbtc), address(wbtc));
        vm.expectRevert(LoopPosition.Slippage.selector);
        account.deposit(p);
        assertEq(_snapshot(), beforeState);
        p = depositParams();
        p.loopPath = route(address(wbtc), address(usds));
        vm.expectRevert(LoopPosition.InvalidPath.selector);
        account.deposit(p);
        assertEq(_snapshot(), beforeState);
        p = depositParams();
        p.ohmPath = new bytes(251);
        vm.expectRevert(LoopPosition.InvalidPath.selector);
        account.deposit(p);
        assertEq(_snapshot(), beforeState);
    }

    function testEmptyPositionCannotAddCollateralOrRepayFx() public {
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.addCollateral(1);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.repayFx(1, 1);
        assertEq(account.contributedWbtc(), 0);
        assertEq(account.fxPositionId(), 0);
    }

    function testInvalidRepaymentsPreserveAnOpenPosition() public {
        _open();
        bytes32 beforeState = _snapshot();
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.addCollateral(0);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.repayFx(0, 1);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.repayFx(2, 1);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.repayCooler(0);
        vm.expectRevert("dust debt");
        account.repayCooler(uint128(31_250e18 - 1));
        assertEq(_snapshot(), beforeState);
    }

    function testSignedCollateralAndRepaymentOverflowFailBeforeProtocolCall() public {
        _open();
        uint256 overflowing = uint256(type(int256).max) + 1;
        wbtc.mint(address(this), overflowing);
        fx.mint(address(this), overflowing);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.addCollateral(overflowing);
        assertEq(_snapshot(), beforeState);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.repayFx(overflowing, overflowing);
        assertEq(_snapshot(), beforeState);
    }

    function testRepaymentSurplusIsRecoverableWithoutChangingCollateral() public {
        _open();
        account.repayFx(50_000e18, 50_000e18 + 1);
        account.repayCooler(uint128(31_250e18 + 1));
        assertEq(pool.debt(account.fxPositionId()), 0);
        assertEq(cooler.debt(address(account)), 0);
        assertEq(pool.collateral(account.fxPositionId()), 1.5225e18);
        assertEq(cooler.collateral(address(account)), 12.5e18);
        assertEq(fx.balanceOf(address(account)), 1);
        assertEq(usds.balanceOf(address(account)), 1);
        uint256 beforeFx = fx.balanceOf(address(this));
        uint256 beforeUsds = usds.balanceOf(address(this));
        account.recover(address(fx));
        account.recover(address(usds));
        assertEq(fx.balanceOf(address(this)), beforeFx + 1);
        assertEq(usds.balanceOf(address(this)), beforeUsds + 1);
    }

    function testManagerCannotReplaceThePositionId() public {
        _open();
        bytes32 beforeState = _snapshot();
        for (uint256 i; i < 2; ++i) {
            vm.mockCall(
                address(manager),
                abi.encodeWithSignature(
                    "operate(address,uint256,int256,int256)",
                    address(pool),
                    account.fxPositionId(),
                    int256(1),
                    int256(0)
                ),
                abi.encode(i == 0 ? 0 : account.fxPositionId() + 1)
            );
            vm.expectRevert(LoopPosition.InvalidInput.selector);
            account.addCollateral(1);
            vm.clearMockedCalls();
            assertEq(_snapshot(), beforeState);
        }
    }

    function testInvalidExitTokenAndUnderbudgetRepaymentAreAtomic() public {
        _open();
        bytes32 beforeState = _snapshot();
        LoopPosition.CloseParams memory p = closeParams();
        p.outputToken = address(0);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.close(p);
        assertEq(_snapshot(), beforeState);
        p.outputToken = bob;
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.close(p);
        assertEq(_snapshot(), beforeState);
        p = closeParams();
        --p.fxRepayBudget;
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.close(p);
        assertEq(_snapshot(), beforeState);
        p = closeParams();
        --p.maxUsdsForFx;
        vm.expectRevert("maxIn");
        account.close(p);
        assertEq(_snapshot(), beforeState);
    }

    function testExitRejectsChangedCallbackDataAndStillAllowsRetry() public {
        _open();
        bytes32 beforeState = _snapshot();
        morpho.setMode(5);
        vm.expectRevert(LoopPosition.InvalidCallback.selector);
        account.close(closeParams());
        assertEq(_snapshot(), beforeState);
        morpho.setMode(0);
        account.close(closeParams());
        assertTrue(account.closed());
        _assertEmpty(account);
    }

    function testExitCannotBurnReceiptWhenProtocolReportsResidualDebt() public {
        _open();
        bytes32 beforeState = _snapshot();
        vm.mockCall(
            address(pool),
            abi.encodeWithSignature("getPosition(uint256)", account.fxPositionId()),
            abi.encode(uint256(1.5225e18), uint256(50_000e18))
        );
        vm.expectRevert(LoopPosition.DebtRemaining.selector);
        account.close(closeParams());
        vm.clearMockedCalls();
        assertEq(_snapshot(), beforeState);
    }

    function testStaleFeedDoesNotPreventFullyFundedExit() public {
        _open();
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.price();
        account.close(closeParams());
        assertTrue(account.closed());
        _assertEmpty(account);
    }

    function testPriceFreshnessBoundaryAndUnsetTimestamp() public {
        feed.set(100_000e8, block.timestamp - 1 hours);
        assertEq(account.price(), 100_000e18);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.price();
        feed.set(100_000e8, 0);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.price();
    }

    function testSafeReceiptTransferRejectionRestoresOwnershipAndApproval() public {
        _open();
        receipt.approve(bob, id);
        RejectingReceiptReceiver receiver = new RejectingReceiptReceiver();
        bytes32 beforeState = _snapshot();
        vm.prank(bob);
        vm.expectRevert("receipt refused");
        receipt.safeTransferFrom(address(this), address(receiver), id);
        assertEq(_snapshot(), beforeState);
        account.close(closeParams());
        assertTrue(account.closed());
    }

    function testOnlyClosedAssociatedAccountCanBurnAndMetadataDisappears() public {
        _open();
        assertGt(bytes(receipt.tokenURI(id)).length, 0);
        vm.expectRevert(LoopReceipt.Unauthorized.selector);
        receipt.burn(id);
        vm.prank(address(account));
        vm.expectRevert(LoopReceipt.Unauthorized.selector);
        receipt.burn(id);
        account.close(closeParams());
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        receipt.tokenURI(id);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        receipt.transferFrom(address(this), bob, id);
        assertEq(receipt.accountOf(id), address(account));
        assertEq(account.finalOwner(), address(this));
    }

    function testEmptyReceiptCanCloseExactlyOnce() public {
        LoopPosition.CloseParams memory p = closeParams();
        p.flashAmount = 0;
        p.minOut = 0;
        assertEq(account.close(p), 0);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.close(p);
        assertTrue(account.closed());
        assertEq(receipt.balanceOf(address(this)), 0);
    }

    function testInvalidAccountAndReceiptConstructors() public {
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        new LoopPosition(address(config), address(receipt), 0);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        new LoopPosition(bob, address(receipt), 1);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        new LoopPosition(address(config), bob, 1);
        vm.expectRevert(LoopReceipt.InvalidConfiguration.selector);
        new LoopReceipt(bob);
        vm.expectRevert("invalid config");
        new LoopAccountDeployer(bob);
        LoopAccountDeployer deployer = receipt.accountDeployer();
        vm.prank(bob);
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        deployer.deploy(1);
    }
}
