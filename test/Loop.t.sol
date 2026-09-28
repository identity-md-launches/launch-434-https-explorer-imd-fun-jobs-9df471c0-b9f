// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoopConfig} from "../src/LoopConfig.sol";
import {LoopReceipt} from "../src/LoopReceipt.sol";
import {LoopPosition} from "../src/LoopPosition.sol";
import {LoopAccountDeployer} from "../src/LoopAccountDeployer.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {
    MockToken,
    MockFeed,
    MockFxPool,
    MockFxManager,
    MockStaking,
    MockCooler,
    MockRouter,
    MockMorpho
} from "./mocks/Protocols.mock.sol";
import {FxSwapRouter} from "../src/FxSwapRouter.sol";
import {MockCurve} from "./Adapters.t.sol";

contract OwnerReentryProbe {
    bool public succeeded;
    bytes public result;

    function deposit(LoopPosition position_, MockToken token_, LoopPosition.DepositParams calldata p) external {
        token_.approve(address(position_), type(uint256).max);
        position_.deposit(p);
    }

    function attack(LoopPosition position_, address token_) external {
        (succeeded, result) = address(position_).call(abi.encodeCall(position_.recover, (token_)));
    }
}

contract FxLockProbe {
    function operateTwice(MockFxManager manager, address pool) external {
        manager.operate(pool, 0, 0, 0);
        manager.operate(pool, 0, 0, 0);
    }
}

abstract contract LoopFixture is Test {
    MockToken wbtc;
    MockToken fx;
    MockToken ohm;
    MockToken gohm;
    MockToken usds;
    MockToken input;
    MockFeed feed;
    MockFxPool pool;
    MockFxManager manager;
    MockStaking staking;
    MockCooler cooler;
    MockRouter router;
    MockMorpho morpho;
    LoopConfig config;
    LoopReceipt receipt;
    LoopPosition account;
    uint256 id;
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_000_000);
        wbtc = new MockToken("WBTC", 8);
        fx = new MockToken("fxUSD", 18);
        ohm = new MockToken("OHM", 9);
        gohm = new MockToken("gOHM", 18);
        usds = new MockToken("USDS", 18);
        input = new MockToken("INPUT", 6);
        feed = new MockFeed();
        pool = new MockFxPool(address(wbtc));
        manager = new MockFxManager(address(fx), address(pool));
        pool.setManager(address(manager));
        staking = new MockStaking(address(ohm), address(gohm));
        cooler = new MockCooler(address(gohm), address(usds), address(ohm), address(staking));
        router = new MockRouter();
        morpho = new MockMorpho();
        config = new LoopConfig(
            address(wbtc),
            address(fx),
            address(ohm),
            address(gohm),
            address(usds),
            address(manager),
            address(pool),
            address(cooler),
            address(staking),
            address(router),
            address(morpho),
            address(feed),
            1 hours
        );
        receipt = new LoopReceipt(address(new LoopAccountDeployer(address(config))));
        address deployed;
        (id, deployed) = receipt.createPosition();
        account = LoopPosition(deployed);
        router.setPrice(address(wbtc), 100_000e18);
        router.setPrice(address(fx), 1e18);
        router.setPrice(address(usds), 1e18);
        router.setPrice(address(input), 1e18);
        router.setPrice(address(ohm), 20e18);
        wbtc.mint(address(this), 1000e8);
        input.mint(address(this), 100_000_000e6);
        usds.mint(address(this), 100_000_000e18);
        fx.mint(address(this), 100_000_000e18);
        wbtc.mint(address(router), 100_000e8);
        ohm.mint(address(router), 100_000_000e9);
        fx.mint(address(router), 1_000_000_000e18);
        usds.mint(address(router), 1_000_000_000e18);
        input.mint(address(router), 1_000_000_000e6);
        usds.mint(address(cooler), 1_000_000_000e18);
        usds.mint(address(morpho), 1_000_000_000e18);
        _approve(account);
    }

    function _approve(LoopPosition a) internal {
        wbtc.approve(address(a), type(uint256).max);
        input.approve(address(a), type(uint256).max);
        usds.approve(address(a), type(uint256).max);
        fx.approve(address(a), type(uint256).max);
    }

    function route(address from, address to) internal pure returns (bytes memory) {
        return abi.encodePacked(from, uint24(3000), to);
    }

    function depositParams() internal view returns (LoopPosition.DepositParams memory p) {
        p.token = address(wbtc);
        p.amount = 1e8;
        p.fxBorrow = 50_000e18;
        p.coolerBorrow = 31_250e18;
        p.wbtcTopUp = 21_000_000;
        p.minWbtc = 1e8;
        p.minOhm = 2500e9;
        p.minGohm = 12.5e18;
        p.minLoopWbtc = 31_250_000;
        p.deadline = block.timestamp;
        p.ohmPath = route(address(fx), address(ohm));
        p.loopPath = route(address(usds), address(wbtc));
    }

    function closeParams() internal view returns (LoopPosition.CloseParams memory p) {
        p.flashAmount = 31_250e18;
        p.minOhm = 2500e9;
        p.minUsds = 50_000e18;
        p.fxRepayBudget = 50_000e18;
        p.maxUsdsForFx = 50_000e18;
        p.maxWbtcForUsds = 31_250_000;
        p.minOut = 121_000_000;
        p.deadline = block.timestamp;
        p.outputToken = address(wbtc);
        p.ohmToUsdsPath = route(address(ohm), address(usds));
        p.usdsToFxPath = route(address(fx), address(usds));
        p.wbtcToUsdsPath = route(address(usds), address(wbtc));
    }

    function _open() internal {
        account.deposit(depositParams());
    }

    function _assertEmpty(LoopPosition a) internal view {
        assertEq(wbtc.balanceOf(address(a)), 0);
        assertEq(fx.balanceOf(address(a)), 0);
        assertEq(ohm.balanceOf(address(a)), 0);
        assertEq(gohm.balanceOf(address(a)), 0);
        assertEq(usds.balanceOf(address(a)), 0);
        assertEq(wbtc.allowance(address(a), address(router)), 0);
        assertEq(usds.allowance(address(a), address(morpho)), 0);
        assertEq(fx.allowance(address(a), address(manager)), 0);
        assertEq(usds.allowance(address(a), address(cooler)), 0);
    }
}

contract LoopTest is LoopFixture {
    function testDepositLoopAndReceipt() public {
        _open();
        (uint256 c, uint256 d, uint256 g, uint256 cd, uint256 ltv) = account.position();
        assertEq(c, 1.5225e18);
        assertEq(d, 50_000e18);
        assertEq(g, 12.5e18);
        assertEq(cd, 31_250e18);
        assertLe(ltv, 0.33e18);
        assertEq(receipt.ownerOf(id), address(this));
        assertEq(account.contributedWbtc(), 121_000_000);
        _assertEmpty(account);
    }

    function testDepositWithTransactionWideFxLock() public {
        manager.setTransactionLock(true);
        // Both calls must share one nested transaction even when Forge uses call isolation.
        FxLockProbe probe = new FxLockProbe();
        vm.expectRevert(MockFxManager.ErrorPoolManagerLocked.selector);
        probe.operateTwice(manager, address(pool));
        assertEq(manager.operateCalls(), 0);
        uint256 lenderBefore = usds.balanceOf(address(morpho));
        uint256 ownerBefore = wbtc.balanceOf(address(this));
        _open();
        assertEq(manager.operateCalls(), 1);
        assertEq(pool.collateral(account.fxPositionId()), 1.5225e18);
        assertEq(pool.debt(account.fxPositionId()), 50_000e18);
        assertEq(usds.balanceOf(address(morpho)), lenderBefore);
        _assertEmpty(account);
        manager.nextTransaction();
        _open();
        assertEq(manager.operateCalls(), 2);
        assertEq(pool.collateral(account.fxPositionId()), 3.045e18);
        assertEq(pool.debt(account.fxPositionId()), 100_000e18);
        assertEq(cooler.debt(address(account)), 62_500e18);
        assertEq(account.contributedWbtc(), 242_000_000);
        (,,,, uint256 ltv) = account.position();
        assertLe(ltv, 0.33e18);

        manager.nextTransaction();
        LoopPosition.CloseParams memory p = closeParams();
        p.flashAmount *= 2;
        p.minOhm *= 2;
        p.minUsds *= 2;
        p.fxRepayBudget *= 2;
        p.maxUsdsForFx *= 2;
        p.maxWbtcForUsds *= 2;
        p.minOut *= 2;
        account.close(p);
        assertEq(manager.operateCalls(), 3);
        assertEq(wbtc.balanceOf(address(this)), ownerBefore);
        assertEq(usds.balanceOf(address(morpho)), lenderBefore);
        assertTrue(account.closed());
        _assertEmpty(account);
    }

    function testAnyRoutableErc20SixDecimalsAndFullExitToSameToken() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.token = address(input);
        p.amount = 100_000e6;
        p.inputPath = route(address(input), address(wbtc));
        account.deposit(p);
        LoopPosition.CloseParams memory c = closeParams();
        c.outputToken = address(input);
        c.outputPath = route(address(wbtc), address(input));
        c.minOut = 121_000e6;
        uint256 beforeInput = input.balanceOf(address(this));
        account.close(c);
        assertEq(input.balanceOf(address(this)) - beforeInput, 121_000e6);
        _assertEmpty(account);
    }

    function testRepeatedDeposits() public {
        _open();
        _open();
        (uint256 c, uint256 d, uint256 g, uint256 cd, uint256 ltv) = account.position();
        assertEq(c, 3.045e18);
        assertEq(d, 100_000e18);
        assertEq(g, 25e18);
        assertEq(cd, 62_500e18);
        assertLe(ltv, 0.33e18);
        assertEq(account.contributedWbtc(), 242_000_000);
    }

    function testEntryFlashCallbackFailuresRollback() public {
        manager.setTransactionLock(true);
        uint256 idleUsds = 100_000e18;
        usds.mint(address(account), idleUsds);
        uint256 ownerBefore = wbtc.balanceOf(address(this));
        uint256 lenderBefore = usds.balanceOf(address(morpho));
        for (uint256 mode = 1; mode <= 5; ++mode) {
            morpho.setMode(mode);
            vm.expectRevert(LoopPosition.InvalidCallback.selector);
            account.deposit(depositParams());
            assertEq(account.fxPositionId(), 0);
            assertEq(manager.operateCalls(), 0);
            assertEq(account.contributedWbtc(), 0);
            assertEq(cooler.debt(address(account)), 0);
            assertEq(gohm.balanceOf(address(cooler)), 0);
            assertEq(wbtc.balanceOf(address(this)), ownerBefore);
            assertEq(usds.balanceOf(address(morpho)), lenderBefore);
            assertEq(usds.balanceOf(address(account)), idleUsds);
            assertEq(usds.allowance(address(account), address(morpho)), 0);
            assertFalse(account.busy());
            assertEq(receipt.ownerOf(id), address(this));
        }
        morpho.setMode(0);
        _open();
        assertEq(manager.operateCalls(), 1);
        vm.prank(address(morpho));
        vm.expectRevert(LoopPosition.InvalidCallback.selector);
        account.onMorphoFlashLoan(31_250e18, abi.encode(depositParams(), uint256(1e8), uint256(100_000e18)));
    }

    function testEntryRequiresFlashLiquidityAndPreservesIdleUsds() public {
        uint256 lenderBefore = usds.balanceOf(address(morpho));
        uint256 ownerBefore = wbtc.balanceOf(address(this));
        usds.mint(address(account), 100_000e18);
        usds.burn(address(morpho), lenderBefore);
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", address(morpho), 0, 31_250e18)
        );
        account.deposit(depositParams());
        assertEq(wbtc.balanceOf(address(this)), ownerBefore);
        assertEq(account.fxPositionId(), 0);
        usds.mint(address(morpho), lenderBefore);
        _open();
        assertEq(usds.balanceOf(address(account)), 100_000e18);
        assertEq(usds.balanceOf(address(morpho)), lenderBefore);
        assertEq(usds.allowance(address(account), address(morpho)), 0);
    }

    function testEntryRejectsShortCoolerDisbursementEvenWithIdleFunds() public {
        usds.mint(address(account), 100_000e18);
        cooler.setDisbursementShortfall(1);
        uint256 lenderBefore = usds.balanceOf(address(morpho));
        uint256 ownerBefore = wbtc.balanceOf(address(this));
        vm.expectRevert(LoopPosition.BadTransfer.selector);
        account.deposit(depositParams());
        assertEq(wbtc.balanceOf(address(this)), ownerBefore);
        assertEq(usds.balanceOf(address(account)), 100_000e18);
        assertEq(usds.balanceOf(address(morpho)), lenderBefore);
        assertEq(account.fxPositionId(), 0);
        assertEq(cooler.debt(address(account)), 0);
        assertEq(gohm.balanceOf(address(cooler)), 0);
    }

    function testEntryCallbackPreservesDynamicRoutesWithNoncanonicalInputOffsets() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.token = address(input);
        p.amount = 100_000e6;
        p.inputPath = route(address(input), address(wbtc));
        p.ohmPath = abi.encodePacked(address(fx), uint24(500), address(usds), uint24(3000), address(ohm));
        // Move the original tuple by one word. Solidity permits this ABI encoding; the callback
        // must preserve the entire argument block and resolve offsets relative to its start.
        bytes memory args = abi.encode(p);
        bytes memory padded = new bytes(args.length + 32);
        for (uint256 i; i < args.length; ++i) {
            padded[i + 32] = args[i];
        }
        assembly ("memory-safe") {
            mstore(add(padded, 32), 64)
        }
        (bool success, bytes memory result) = address(account).call(abi.encodePacked(account.deposit.selector, padded));
        assertTrue(success, string(result));
        assertEq(pool.collateral(account.fxPositionId()), 1.5225e18);
        assertEq(pool.debt(account.fxPositionId()), 50_000e18);
        assertEq(cooler.debt(address(account)), 31_250e18);
        _assertEmpty(account);
    }

    function testFullUnwindConservesCapitalAndFlashLiquidity() public {
        uint256 wbtcBefore = wbtc.balanceOf(address(this));
        uint256 lenderBefore = usds.balanceOf(address(morpho));
        _open();
        account.close(closeParams());
        assertEq(wbtc.balanceOf(address(this)), wbtcBefore);
        assertEq(usds.balanceOf(address(morpho)), lenderBefore);
        assertTrue(account.closed());
        assertEq(receipt.balanceOf(address(this)), 0);
        _assertEmpty(account);
        (uint256 c, uint256 d, uint256 g, uint256 cd,) = account.position();
        assertEq(c + d + g + cd, 0);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.deposit(depositParams());
    }

    function testAccruedDebtsAndRepaymentFeePaidFromCapital() public {
        _open();
        cooler.accrue(address(account), 100e18);
        pool.accrue(account.fxPositionId(), 500e18);
        manager.setFees(0, 0, 100);
        LoopPosition.CloseParams memory p = closeParams();
        p.fxRepayBudget = 51_005e18;
        p.maxUsdsForFx = p.fxRepayBudget;
        p.flashAmount = 32_355e18;
        p.maxWbtcForUsds = 32_355_000;
        p.minOut = 119_895_000;
        uint256 beforeWbtc = wbtc.balanceOf(address(this));
        account.close(p);
        assertEq(wbtc.balanceOf(address(this)) - beforeWbtc, p.minOut);
        _assertEmpty(account);
    }

    function testUnwindWithoutFlashLoanUsesOwnerBridgeFunds() public {
        _open();
        LoopPosition.CloseParams memory p = closeParams();
        p.flashAmount = 0;
        p.usdsTopUp = 31_250e18;
        p.minOut = 152_250_000;
        account.close(p);
        assertTrue(account.closed());
        _assertEmpty(account);
    }

    function testOwnerCanReduceRiskWithStaleOracle() public {
        _open();
        vm.warp(block.timestamp + 2 hours);
        account.addCollateral(1e8);
        account.repayFx(1000e18, 1000e18);
        account.repayCooler(1000e18);
        assertEq(pool.debt(account.fxPositionId()), 49_000e18);
        assertEq(cooler.debt(address(account)), 30_250e18);
        assertEq(account.contributedWbtc(), 221_000_000);
    }

    function testReceiptTransferMovesAllRights() public {
        _open();
        receipt.transferFrom(address(this), bob, id);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.close(closeParams());
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.addCollateral(1);
        vm.prank(bob);
        account.close(closeParams());
        assertEq(wbtc.balanceOf(bob), 121_000_000);
    }

    function testApprovedNftOperatorCannotSpendPositionFunds() public {
        _open();
        receipt.approve(bob, id);
        vm.prank(bob);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.recover(address(wbtc));
        vm.prank(bob);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.repayCooler(1000e18);
    }

    function testOtherUsersCannotBurnOrWithdraw() public {
        _open();
        vm.startPrank(bob);
        vm.expectRevert(LoopReceipt.Unauthorized.selector);
        receipt.burn(id);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.close(closeParams());
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.deposit(depositParams());
        vm.stopPrank();
    }

    function testIndependentPositions() public {
        _open();
        vm.prank(bob);
        (uint256 otherId, address other) = receipt.createPosition();
        wbtc.mint(bob, 2e8);
        vm.startPrank(bob);
        wbtc.approve(other, type(uint256).max);
        LoopPosition(other).deposit(depositParams());
        vm.stopPrank();
        account.close(closeParams());
        assertEq(receipt.ownerOf(otherId), bob);
        assertEq(cooler.debt(other), 31_250e18);
        assertEq(pool.debt(LoopPosition(other).fxPositionId()), 50_000e18);
    }

    function testInsufficientReinvestmentRevertsEverything() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.wbtcTopUp = 0;
        uint256 beforeWbtc = wbtc.balanceOf(address(this));
        vm.expectRevert(LoopPosition.UnsafeLtv.selector);
        account.deposit(p);
        assertEq(account.fxPositionId(), 0);
        assertEq(cooler.debt(address(account)), 0);
        assertEq(wbtc.balanceOf(address(this)), beforeWbtc);
    }

    function testInitialBorrowMustBeNearFiftyPercent() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.fxBorrow = 50_001e18;
        vm.expectRevert(LoopPosition.UnsafeLtv.selector);
        account.deposit(p);
        p.fxBorrow = 48_999e18;
        vm.expectRevert(LoopPosition.UnsafeLtv.selector);
        account.deposit(p);
    }

    function testPoolOracleAlsoEnforcesFinalLtv() public {
        pool.setPrice(90_000e18);
        vm.expectRevert(LoopPosition.UnsafeLtv.selector);
        account.deposit(depositParams());
    }

    function testSupplyAndBorrowFeesRequireAdjustedQuote() public {
        manager.setFees(100, 100, 0);
        LoopPosition.DepositParams memory p = depositParams();
        vm.expectRevert(LoopPosition.UnsafeLtv.selector);
        account.deposit(p);
        p.fxBorrow = 49_500e18;
        p.minOhm = 2400e9;
        p.minGohm = 12e18;
        p.coolerBorrow = 30_000e18;
        p.minLoopWbtc = 30_000_000;
        p.wbtcTopUp = 25_000_000;
        account.deposit(p);
        (,,,, uint256 ltv) = account.position();
        assertLe(ltv, 0.33e18);
    }

    function testDeadlineAndZeroAmount() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.deadline--;
        vm.expectRevert(LoopPosition.Expired.selector);
        account.deposit(p);
        p = depositParams();
        p.amount = 0;
        vm.expectRevert(LoopPosition.InvalidInput.selector);
        account.deposit(p);
    }

    function testInvalidAndStaleFeed() public {
        feed.set(0, block.timestamp);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.deposit(depositParams());
        feed.set(-1, block.timestamp);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.price();
        feed.set(100_000e8, block.timestamp + 1);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.price();
        feed.set(100_000e8, block.timestamp - 3601);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.price();
        feed.set(100_000e8, block.timestamp);
        feed.setRound(0);
        vm.expectRevert(LoopPosition.StalePrice.selector);
        account.price();
    }

    function testSwapFailureAndMisreportedOutputRollback() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.minOhm++;
        vm.expectRevert("minOut");
        account.deposit(p);
        assertEq(account.fxPositionId(), 0);
        router.setLie(true);
        vm.expectRevert(LoopPosition.Slippage.selector);
        account.deposit(depositParams());
    }

    function testRejectsWrongPathEndpointsAndMalformedPath() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.ohmPath = route(address(usds), address(ohm));
        vm.expectRevert(LoopPosition.InvalidPath.selector);
        account.deposit(p);
        p.ohmPath = hex"1234";
        vm.expectRevert(LoopPosition.InvalidPath.selector);
        account.deposit(p);
    }

    function testFeeOnTransferDepositRejected() public {
        input.setTax(100);
        LoopPosition.DepositParams memory p = depositParams();
        p.token = address(input);
        p.amount = 100_000e6;
        p.inputPath = route(address(input), address(wbtc));
        vm.expectRevert(LoopPosition.BadTransfer.selector);
        account.deposit(p);
    }

    function testWarmupOrCoolerBorrowFailureRollsBack() public {
        staking.setWarmup(true);
        vm.expectRevert(LoopPosition.Slippage.selector);
        account.deposit(depositParams());
        staking.setWarmup(false);
        cooler.setPaused(true);
        vm.expectRevert();
        account.deposit(depositParams());
        assertEq(account.fxPositionId(), 0);
        assertEq(gohm.balanceOf(address(cooler)), 0);
    }

    function testCoolerMinimumAndMaxBorrow() public {
        LoopPosition.DepositParams memory p = depositParams();
        p.coolerBorrow = 31_251e18;
        vm.expectRevert("cooler limits");
        account.deposit(p);
        p.coolerBorrow = 999e18;
        p.minLoopWbtc = 999_000;
        vm.expectRevert("cooler limits");
        account.deposit(p);
    }

    function testDependencyChangesFailClosed() public {
        manager.setScale(1e27);
        vm.expectRevert(LoopPosition.DependencyChanged.selector);
        account.deposit(depositParams());
        manager.setScale(1e28);
        cooler.setDebtToken(address(fx));
        vm.expectRevert(LoopPosition.DependencyChanged.selector);
        account.deposit(depositParams());
    }

    function testUnauthorizedAndReplayedCallbackRejected() public {
        vm.expectRevert(LoopPosition.InvalidCallback.selector);
        account.onMorphoFlashLoan(1, "");
        vm.prank(address(morpho));
        vm.expectRevert(LoopPosition.InvalidCallback.selector);
        account.onMorphoFlashLoan(1, "");
        _open();
        morpho.setMode(3);
        vm.expectRevert(LoopPosition.InvalidCallback.selector);
        account.close(closeParams());
        assertFalse(account.closed());
        assertEq(receipt.ownerOf(id), address(this));
    }

    function testLenderCannotSkipCallbackOrLieAboutAmountOrFunding() public {
        _open();
        for (uint256 i = 1; i <= 4; ++i) {
            morpho.setMode(i);
            vm.expectRevert(LoopPosition.InvalidCallback.selector);
            account.close(closeParams());
            assertFalse(account.closed());
            assertEq(cooler.debt(address(account)), 31_250e18);
        }
    }

    function testSwapCannotTransferReceiptMidOperation() public {
        receipt.approve(address(router), id);
        router.setHook(address(receipt), abi.encodeCall(receipt.transferFrom, (address(this), bob, id)));
        _open();
        assertFalse(router.hookSucceeded());
        assertEq(receipt.ownerOf(id), address(this));
    }

    function testSwapCannotReenterUnwind() public {
        router.setHook(address(account), abi.encodeCall(account.close, (closeParams())));
        _open();
        assertFalse(router.hookSucceeded());
        assertFalse(account.closed());
    }

    function testAuthorizedOwnerCallbackHitsReentrancyGuard() public {
        OwnerReentryProbe probe = new OwnerReentryProbe();
        receipt.transferFrom(address(this), address(probe), id);
        wbtc.mint(address(probe), 2e8);
        router.setHook(address(probe), abi.encodeCall(probe.attack, (account, address(wbtc))));
        probe.deposit(account, wbtc, depositParams());
        assertFalse(probe.succeeded());
        assertEq(probe.result(), abi.encodeWithSelector(LoopPosition.Busy.selector));
    }

    function testFullLoopAndUnwindThroughCurveBridge() public {
        MockToken usdc = new MockToken("USDC", 6);
        MockCurve curve = new MockCurve(address(usdc), address(fx));
        FxSwapRouter bridge =
            new FxSwapRouter(address(router), address(router), address(curve), address(fx), address(usdc));
        usdc.mint(address(curve), 10_000_000e6);
        fx.mint(address(curve), 10_000_000e18);
        usdc.mint(address(router), 10_000_000e6);
        router.setPrice(address(usdc), 1e18);
        LoopConfig bridgedConfig = new LoopConfig(
            address(wbtc),
            address(fx),
            address(ohm),
            address(gohm),
            address(usds),
            address(manager),
            address(pool),
            address(cooler),
            address(staking),
            address(bridge),
            address(morpho),
            address(feed),
            1 hours
        );
        LoopReceipt bridgedReceipt = new LoopReceipt(address(new LoopAccountDeployer(address(bridgedConfig))));
        (, address deployed) = bridgedReceipt.createPosition();
        LoopPosition a = LoopPosition(deployed);
        _approve(a);
        LoopPosition.DepositParams memory d = depositParams();
        d.ohmPath = abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(ohm));
        d.minOhm = 2498e9;
        d.minGohm = 12.49e18;
        d.coolerBorrow = 31_200e18;
        d.minLoopWbtc = 31_200_000;
        a.deposit(d);
        LoopPosition.CloseParams memory c = closeParams();
        c.minOhm = d.minOhm;
        c.minUsds = 49_950e18;
        c.flashAmount = 31_400e18;
        c.maxWbtcForUsds = 31_400_000;
        c.maxUsdsForFx = 50_100e18;
        c.minOut = 120_000_000;
        c.usdsToFxPath = abi.encodePacked(address(fx), uint24(0), address(usdc), uint24(3000), address(usds));
        a.close(c);
        assertTrue(a.closed());
        _assertEmpty(a);
        assertEq(usdc.balanceOf(address(bridge)), 0);
        assertEq(fx.balanceOf(address(bridge)), 0);
    }

    function testExitSlippageAndUnderfundingAreAtomic() public {
        _open();
        LoopPosition.CloseParams memory p = closeParams();
        p.maxWbtcForUsds--;
        vm.expectRevert("maxIn");
        account.close(p);
        p = closeParams();
        p.minOut++;
        vm.expectRevert(LoopPosition.Slippage.selector);
        account.close(p);
        p = closeParams();
        p.flashAmount--;
        vm.expectRevert();
        account.close(p);
        assertEq(pool.debt(account.fxPositionId()), 50_000e18);
        assertEq(cooler.debt(address(account)), 31_250e18);
        assertEq(receipt.ownerOf(id), address(this));
    }

    function testTopUpCanCoverMarketLossOnExit() public {
        _open();
        router.setPrice(address(ohm), 16e18);
        LoopPosition.CloseParams memory p = closeParams();
        p.minUsds = 40_000e18;
        p.usdsTopUp = 10_000e18;
        account.close(p);
        assertTrue(account.closed());
    }

    function testTaxedOutputCannotUndercutWalletMinimum() public {
        _open();
        input.setTax(100);
        LoopPosition.CloseParams memory p = closeParams();
        p.outputToken = address(input);
        p.outputPath = route(address(wbtc), address(input));
        p.minOut = 119_790e6;
        vm.expectRevert(LoopPosition.Slippage.selector);
        account.close(p);
        assertFalse(account.closed());
        assertEq(cooler.debt(address(account)), 31_250e18);
    }

    function testDirectFxBurnCannotExceedRepaymentBudget() public {
        _open();
        fx.mint(address(account), 5000e18);
        manager.setFees(0, 0, 100);
        vm.expectRevert(LoopPosition.Slippage.selector);
        account.repayFx(1000e18, 1000e18);
        assertEq(pool.debt(account.fxPositionId()), 50_000e18);
        fx.mint(address(account), 50_000e18);
        vm.expectRevert(LoopPosition.Slippage.selector);
        account.close(closeParams());
        assertEq(fx.balanceOf(address(account)), 55_000e18);
    }

    function testDebtTokenMigrationCanExitAfterExternalFullRepayment() public {
        _open();
        cooler.setDebtToken(address(input));
        vm.expectRevert(LoopPosition.DependencyChanged.selector);
        account.close(closeParams());
        input.mint(address(this), 31_250e18);
        input.approve(address(cooler), 31_250e18);
        cooler.repay(uint128(31_250e18), address(account));
        LoopPosition.CloseParams memory p = closeParams();
        p.flashAmount = 0;
        p.minOut = 152_250_000;
        account.close(p);
        assertTrue(account.closed());
    }

    function testDonationsRecoverableBeforeAndAfterBurn() public {
        input.mint(address(account), 123);
        account.recover(address(input));
        assertEq(input.balanceOf(address(account)), 0);
        _open();
        account.close(closeParams());
        input.mint(address(account), 456);
        account.recover(address(input));
        vm.prank(bob);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        account.recover(address(input));
    }

    function testFullyLiquidatedPositionCanCloseWithExplicitZeroReturn() public {
        _open();
        pool.liquidate(account.fxPositionId());
        cooler.liquidate(address(account));
        LoopPosition.CloseParams memory p = closeParams();
        p.flashAmount = 0;
        p.minOut = 0;
        account.close(p);
        assertTrue(account.closed());
        assertEq(receipt.balanceOf(address(this)), 0);
    }

    function testFuzzRepeatedLoopsConserveCapital(uint96 seed, uint8 countSeed) public {
        uint256 units = bound(seed, 1, 20);
        uint256 count = bound(countSeed, 1, 4);
        uint256 beforeWbtc = wbtc.balanceOf(address(this));
        LoopPosition.DepositParams memory d = depositParams();
        d.amount *= units;
        d.fxBorrow *= units;
        d.coolerBorrow = uint128(uint256(d.coolerBorrow) * units);
        d.wbtcTopUp *= units;
        for (uint256 i; i < count; ++i) {
            account.deposit(d);
            (,,,, uint256 ltv) = account.position();
            assertLe(ltv, 0.33e18);
        }
        LoopPosition.CloseParams memory p = closeParams();
        p.flashAmount *= units * count;
        p.fxRepayBudget *= units * count;
        p.maxUsdsForFx *= units * count;
        p.maxWbtcForUsds *= units * count;
        p.minOut *= units * count;
        account.close(p);
        assertEq(wbtc.balanceOf(address(this)), beforeWbtc);
        _assertEmpty(account);
    }

    function testDeploymentRuntimeHasNoEscapeOpcodes() public view {
        _runtime(address(config));
        _runtime(address(receipt));
        _runtime(address(account));
        _runtime(address(receipt.accountDeployer()));
    }

    function _runtime(address a) internal view {
        bytes memory code = a.code;
        assertLe(code.length, 24576);
        assertGt(code.length, 0);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
        }
    }
}

contract LaunchTokenTest is Test {
    function testSupplyTransferAndNoMint() public {
        LaunchToken token = new LaunchToken();
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        token.transfer(address(0xBEEF), 1e18);
        assertEq(token.balanceOf(address(0xBEEF)), 1e18);
        (bool success,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(success);
        assertEq(token.totalSupply(), 1e27);
    }
}
