// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LoopFixture} from "./Loop.t.sol";
import {LoopPosition} from "src/LoopPosition.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {MockToken} from "./mocks/Protocols.mock.sol";

/// @dev The fixture models fixed prices, no fees and no liquidation. Ghosts are updated from
/// user inputs, never copied from the protocol's post-call accounting. All funding happens
/// before the campaign; donations and repayments spend the actors' existing balances.
contract LoopSequenceHandler is LoopFixture {
    struct Record {
        LoopPosition position;
        uint256 tokenId;
        address owner;
        uint256 contributed;
        uint256 collateral;
        uint256 fxDebt;
        uint256 gohmCollateral;
        uint256 coolerDebt;
        bool closed;
    }

    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA11)];
    Record[] internal records;
    uint256[3] internal current;
    uint256 public initialWealth;
    uint256 public initialLenderBalance;
    uint256 public deposits;
    uint256 public closes;
    uint256 public accruedInterest;

    constructor() {
        setUp();
        manager.setTransactionLock(true);
        for (uint256 i; i < 3; ++i) {
            wbtc.mint(actors[i], 10_000e8);
            fx.mint(actors[i], 100_000_000e18);
            usds.mint(actors[i], 100_000_000e18);
            input.mint(actors[i], 100_000_000e6);
            initialWealth += _idleValue(actors[i]);
            if (i == 0) {
                receipt.transferFrom(address(this), actors[i], id);
                records.push(Record(account, id, actors[i], 0, 0, 0, 0, 0, false));
            } else {
                _create(actors[i]);
            }
            current[i] = i;
        }
        initialLenderBalance = usds.balanceOf(address(morpho));
        for (uint256 i; i < 3; ++i) {
            deposit(i, 1e8);
        }
    }

    function _create(address owner) internal returns (uint256 index) {
        vm.prank(owner);
        (uint256 tokenId, address position_) = receipt.createPosition();
        index = records.length;
        records.push(Record(LoopPosition(position_), tokenId, owner, 0, 0, 0, 0, 0, false));
    }

    function _active(uint256 seed) internal returns (uint256 index) {
        uint256 slot = seed % 3;
        index = current[slot];
        if (records[index].closed) {
            index = _create(actors[slot]);
            current[slot] = index;
        }
    }

    function deposit(uint256 accountSeed, uint256 amountSeed) public {
        Record storage r = records[_active(accountSeed)];
        // Arbitrary WBTC minor units, with enough Cooler debt to meet its $1,000 minimum.
        uint256 amount = bound(amountSeed, 4_000_000, 2e8);
        LoopPosition.DepositParams memory p = depositParams();
        p.amount = amount;
        p.minWbtc = amount;
        p.wbtcTopUp = (amount + 1) / 2;
        p.fxBorrow = amount * 5e14;
        p.minOhm = amount * 25_000;
        p.minGohm = amount * 125e9;
        p.coolerBorrow = uint128(p.minGohm * 2000);
        p.minLoopWbtc = amount / 4;
        manager.nextTransaction();
        vm.startPrank(r.owner);
        _approve(r.position);
        r.position.deposit(p);
        vm.stopPrank();
        r.contributed += amount + p.wbtcTopUp;
        r.collateral += (amount + p.wbtcTopUp + amount / 4) * 1e10;
        r.fxDebt += p.fxBorrow;
        r.gohmCollateral += p.minGohm;
        r.coolerDebt += p.coolerBorrow;
        ++deposits;
        (,,,, uint256 ltv) = r.position.position();
        assertLe(ltv, 0.33e18, "entry LTV");
    }

    function addCollateral(uint256 accountSeed, uint256 amountSeed) external {
        Record storage r = records[_active(accountSeed)];
        if (r.position.fxPositionId() == 0) deposit(accountSeed, 4_000_000);
        uint256 amount = bound(amountSeed, 1, 1e8);
        manager.nextTransaction();
        vm.startPrank(r.owner);
        wbtc.approve(address(r.position), amount);
        r.position.addCollateral(amount);
        vm.stopPrank();
        r.contributed += amount;
        r.collateral += amount * 1e10;
    }

    function repayFx(uint256 accountSeed, uint256 amountSeed, uint256 surplusSeed) external {
        Record storage r = records[_active(accountSeed)];
        if (r.fxDebt == 0) deposit(accountSeed, 4_000_000);
        uint256 amount = bound(amountSeed, 1, r.fxDebt);
        uint256 budget = amount + bound(surplusSeed, 0, 10e18);
        manager.nextTransaction();
        vm.startPrank(r.owner);
        fx.approve(address(r.position), budget);
        r.position.repayFx(amount, budget);
        vm.stopPrank();
        r.fxDebt -= amount;
    }

    function repayCooler(uint256 accountSeed, uint256 seed, bool inFull) external {
        Record storage r = records[_active(accountSeed)];
        if (r.coolerDebt == 0) deposit(accountSeed, 4_000_000);
        // Partial repayment may not leave debt below the upstream minimum.
        uint256 amount = inFull || r.coolerDebt <= 1000e18 ? r.coolerDebt : bound(seed, 1, r.coolerDebt - 1000e18);
        vm.startPrank(r.owner);
        usds.approve(address(r.position), amount);
        r.position.repayCooler(uint128(amount));
        vm.stopPrank();
        r.coolerDebt -= amount;
    }

    function accrue(uint256 seed, uint256 amountSeed, bool fxSide) external {
        Record storage r = records[current[seed % 3]];
        uint256 debt = fxSide ? r.fxDebt : r.coolerDebt;
        if (r.closed || debt == 0) return;
        uint256 amount = bound(amountSeed, 1, 1e18);
        if (fxSide) {
            pool.accrue(r.position.fxPositionId(), amount);
            r.fxDebt += amount;
        } else {
            cooler.accrue(address(r.position), amount);
            r.coolerDebt += amount;
        }
        accruedInterest += amount;
    }

    function transferReceipt(uint256 seed, uint256 recipientSeed, bool viaOperator) external {
        Record storage r = records[_active(seed)];
        address recipient = actors[recipientSeed % 3];
        address previous = r.owner;
        if (viaOperator) {
            vm.prank(previous);
            receipt.approve(address(this), r.tokenId);
            receipt.transferFrom(previous, recipient, r.tokenId);
        } else {
            vm.prank(previous);
            receipt.transferFrom(previous, recipient, r.tokenId);
        }
        r.owner = recipient;
        assertEq(receipt.getApproved(r.tokenId), address(0), "approval survives transfer");
        if (previous != recipient) {
            vm.prank(previous);
            vm.expectRevert(LoopPosition.Unauthorized.selector);
            r.position.recover(address(wbtc));
        }
    }

    function donate(uint256 seed, uint256 tokenSeed, uint256 amountSeed, uint256 actorSeed) external {
        Record storage r = records[seed % records.length];
        MockToken token = _donationToken(tokenSeed);
        address donor = actors[actorSeed % 3];
        uint256 amount = bound(amountSeed, 0, 10 ** token.decimals());
        vm.prank(donor);
        token.transfer(address(r.position), amount);
    }

    function recover(uint256 seed, uint256 tokenSeed) external {
        Record storage r = records[seed % records.length];
        MockToken token = _donationToken(tokenSeed);
        uint256 amount = token.balanceOf(address(r.position));
        uint256 beforeBalance = token.balanceOf(r.owner);
        vm.prank(r.owner);
        r.position.recover(address(token));
        assertEq(token.balanceOf(r.owner), beforeBalance + amount);
        assertEq(token.balanceOf(address(r.position)), 0);
    }

    function unauthorized(uint256 seed, uint256 operation) external {
        Record storage r = records[seed % records.length];
        address attacker = address(0xBAD);
        vm.startPrank(attacker);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        if (operation % 6 == 0) r.position.deposit(depositParams());
        else if (operation % 6 == 1) r.position.close(closeParams());
        else if (operation % 6 == 2) r.position.addCollateral(1);
        else if (operation % 6 == 3) r.position.repayFx(1, 1);
        else if (operation % 6 == 4) r.position.repayCooler(1);
        else r.position.recover(address(input));
        vm.stopPrank();
    }

    function close(uint256 seed) public {
        _close(current[seed % 3]);
    }

    function _close(uint256 index) internal {
        Record storage r = records[index];
        if (r.closed) {
            vm.prank(r.owner);
            vm.expectRevert(LoopPosition.Unauthorized.selector);
            r.position.close(closeParams());
            return;
        }
        LoopPosition.CloseParams memory p = closeParams();
        // Bridge both current debts. Unused flash liquidity is returned to Morpho.
        p.flashAmount = r.coolerDebt + r.fxDebt;
        p.fxRepayBudget = r.fxDebt;
        p.maxUsdsForFx = r.fxDebt;
        p.maxWbtcForUsds = r.collateral / 1e10;
        p.minOhm = r.gohmCollateral == 0 ? 0 : 1;
        p.minUsds = r.gohmCollateral == 0 ? 0 : 1;
        p.minOut = r.collateral != 0 || wbtc.balanceOf(address(r.position)) != 0 ? 1 : 0;
        uint256 beforeWbtc = wbtc.balanceOf(r.owner);
        manager.nextTransaction();
        vm.prank(r.owner);
        uint256 returned = r.position.close(p);
        assertEq(wbtc.balanceOf(r.owner) - beforeWbtc, returned, "close return value");
        r.closed = true;
        r.collateral = 0;
        r.fxDebt = 0;
        r.gohmCollateral = 0;
        r.coolerDebt = 0;
        ++closes;
        _assertEmpty(r.position);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, r.tokenId));
        receipt.ownerOf(r.tokenId);
        vm.prank(r.owner);
        vm.expectRevert(LoopPosition.Unauthorized.selector);
        r.position.deposit(depositParams());
    }

    function _donationToken(uint256 seed) internal view returns (MockToken) {
        if (seed % 4 == 0) return wbtc;
        if (seed % 4 == 1) return fx;
        if (seed % 4 == 2) return usds;
        return input;
    }

    function _idleValue(address holder) internal view returns (uint256) {
        return
            wbtc.balanceOf(holder) * 1e15 + fx.balanceOf(holder) + usds.balanceOf(holder) + input.balanceOf(holder)
                * 1e12;
    }

    function assertAccounting() external view {
        uint256 collateralSum;
        uint256 gohmSum;
        uint256 wealth;
        uint256[3] memory receiptBalances;
        for (uint256 i; i < 3; ++i) {
            wealth += _idleValue(actors[i]);
        }
        for (uint256 i; i < records.length; ++i) {
            Record storage r = records[i];
            (uint256 c, uint256 d, uint256 g, uint256 cd,) = r.position.position();
            assertEq(c, r.collateral, "f(x) collateral ledger");
            assertEq(d, r.fxDebt, "f(x) debt ledger");
            assertEq(g, r.gohmCollateral, "Cooler collateral ledger");
            assertEq(cd, r.coolerDebt, "Cooler debt ledger");
            assertEq(r.position.contributedWbtc(), r.contributed, "historical contributions");
            assertEq(r.position.closed(), r.closed, "terminal state");
            assertFalse(r.position.busy(), "operation lock left set");
            assertEq(receipt.accountOf(r.tokenId), address(r.position));
            assertEq(address(r.position.receipt()), address(receipt));
            assertEq(r.position.receiptId(), r.tokenId);
            assertEq(address(r.position.config()), address(config));
            if (r.closed) {
                assertEq(r.position.finalOwner(), r.owner);
            } else {
                assertEq(receipt.ownerOf(r.tokenId), r.owner, "receipt owner ledger");
                assertEq(r.position.finalOwner(), address(0));
                for (uint256 j; j < 3; ++j) {
                    if (r.owner == actors[j]) ++receiptBalances[j];
                }
            }
            collateralSum += c / 1e10;
            gohmSum += g;
            wealth += _idleValue(address(r.position)) + c * 1e5 + g * 4000 - d - cd;
            address[5] memory tokens = [address(wbtc), address(fx), address(ohm), address(gohm), address(usds)];
            address[5] memory spenders =
                [address(router), address(manager), address(staking), address(cooler), address(morpho)];
            for (uint256 j; j < 5; ++j) {
                for (uint256 k; k < 5; ++k) {
                    assertEq(MockToken(tokens[j]).allowance(address(r.position), spenders[k]), 0, "lingering approval");
                }
            }
            assertEq(ohm.balanceOf(address(r.position)), 0);
            assertEq(gohm.balanceOf(address(r.position)), 0);
        }
        for (uint256 i; i < 3; ++i) {
            assertEq(receipt.balanceOf(actors[i]), receiptBalances[i]);
        }
        assertEq(receipt.nextId(), records.length + 1);
        assertEq(wbtc.balanceOf(address(pool)), collateralSum, "pool custody backs all positions");
        assertEq(gohm.balanceOf(address(cooler)), gohmSum, "Cooler custody backs all positions");
        assertEq(usds.balanceOf(address(morpho)), initialLenderBalance, "flash principal conserved");
        assertLe(wealth + accruedInterest, initialWealth, "sequence created value");
        // Each entry can truncate one satoshi; each exit can round up one satoshi.
        assertLe(initialWealth - wealth - accruedInterest, (deposits + closes) * 1e15, "unexplained loss");
    }

    function finish() external {
        for (uint256 i; i < 3; ++i) {
            _close(current[i]);
        }
        for (uint256 i; i < records.length; ++i) {
            Record storage r = records[i];
            for (uint256 j; j < 4; ++j) {
                MockToken token = _donationToken(j);
                vm.prank(r.owner);
                r.position.recover(address(token));
                assertEq(token.balanceOf(address(r.position)), 0);
            }
        }
        assertEq(wbtc.balanceOf(address(pool)), 0);
        assertEq(gohm.balanceOf(address(cooler)), 0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LoopInvariantTest is Test {
    LoopSequenceHandler handler;

    function setUp() public {
        handler = new LoopSequenceHandler();
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.addCollateral.selector;
        selectors[2] = handler.repayFx.selector;
        selectors[3] = handler.repayCooler.selector;
        selectors[4] = handler.accrue.selector;
        selectors[5] = handler.transferReceipt.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.recover.selector;
        selectors[8] = handler.unauthorized.selector;
        selectors[9] = handler.close.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_custodyDebtsOwnershipAndValueConservation() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.finish();
        handler.assertAccounting();
    }

    function testSequenceExercisesRepaymentTransferDonationClosureAndReentry() public {
        handler.deposit(0, 4_000_001);
        handler.addCollateral(1, 1);
        handler.repayFx(0, 1, 1e18);
        handler.repayCooler(1, 0, true);
        handler.accrue(2, 1, true);
        handler.accrue(2, 1, false);
        handler.transferReceipt(0, 1, true);
        handler.donate(0, 0, 1, 2);
        handler.close(0);
        handler.donate(0, 3, 1, 2);
        handler.recover(0, 3);
        handler.deposit(0, 4_000_003);
        handler.unauthorized(0, 0);
        handler.assertAccounting();
        handler.finish();
        handler.assertAccounting();
        assertGt(handler.deposits(), 3);
        assertGt(handler.closes(), 0);
    }
}
