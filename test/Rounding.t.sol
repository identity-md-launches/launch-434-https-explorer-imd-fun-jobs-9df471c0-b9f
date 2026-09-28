// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LoopFixture} from "./Loop.t.sol";
import {LoopPosition} from "../src/LoopPosition.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Exercise arbitrary minor units, not only whole-token multiples.
contract RoundingTest is LoopFixture {
    function testReportedFxusdShortfallNeedsRoundingBridge() public {
        uint256 debt = 2368693941673936653513;
        _roundTrip(Math.ceilDiv(debt * 2, 1e15), debt, 100_000e18, 20e18, true);
    }

    function testFuzzDepositThenCloseWithFractionalQuotes(uint256 amountSeed, uint256 priceSeed, uint256 ohmSeed)
        public
    {
        uint256 amount = bound(amountSeed, 1e8, 20e8);
        uint256 px = bound(priceSeed, 20_000e8, 200_000e8) * 1e10;
        // Keep the mock's $12.50/OHM Cooler backing below its market price.
        uint256 ohmPrice = bound(ohmSeed, 15e18, 25e18);
        uint256 debt = Math.mulDiv(amount, px, 2e8);
        _roundTrip(amount, debt, px, ohmPrice, false);
    }

    function _roundTrip(uint256 amount, uint256 debt, uint256 px, uint256 ohmPrice, bool reproduce) private {
        router.setPrice(address(wbtc), px);
        router.setPrice(address(ohm), ohmPrice);
        pool.setPrice(px);
        feed.set(int256(px / 1e10), block.timestamp);
        manager.setTransactionLock(true);
        uint256 ownerBefore = wbtc.balanceOf(address(this));
        uint256 lenderBefore = usds.balanceOf(address(morpho));
        LoopPosition.DepositParams memory d = depositParams();
        d.amount = amount;
        d.minWbtc = amount;
        d.fxBorrow = debt;
        d.minOhm = router.quoteExactInput(d.ohmPath, debt);
        d.minGohm = d.minOhm * 1e9 / 200;
        d.coolerBorrow = uint128(d.minGohm * 2500 * 99 / 100);
        d.minLoopWbtc = router.quoteExactInput(d.loopPath, d.coolerBorrow);
        d.wbtcTopUp = Math.ceilDiv(amount, 2);
        account.deposit(d);
        (,,,, uint256 ltv) = account.position();
        assertLe(ltv, 0.33e18);
        manager.nextTransaction();

        LoopPosition.CloseParams memory p = closeParams();
        p.flashAmount = d.coolerBorrow;
        p.minOhm = d.minOhm;
        p.minUsds = router.quoteExactInput(p.ohmToUsdsPath, d.minOhm);
        p.fxRepayBudget = debt;
        p.maxUsdsForFx = router.quoteExactOutput(p.usdsToFxPath, debt);
        uint256 shortfall = p.maxUsdsForFx - p.minUsds;
        if (reproduce) {
            assertEq(p.minUsds, 2368693941660000000000);
            assertEq(shortfall, 13936653513);
            // Borrowing only Cooler debt leaves the rounded OHM sale short of fxUSD repayment.
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientBalance.selector, address(account), p.minUsds, debt
                )
            );
            account.close(p);
            assertEq(pool.debt(account.fxPositionId()), debt);
            assertEq(cooler.debt(address(account)), d.coolerBorrow);
            assertEq(receipt.ownerOf(id), address(this));
            assertEq(usds.balanceOf(address(morpho)), lenderBefore);
        }
        // Bridge the exact shortfall; debt is still repaid in full, with no tolerance or write-off.
        p.flashAmount += shortfall;
        p.maxWbtcForUsds = router.quoteExactOutput(p.wbtcToUsdsPath, p.flashAmount);
        p.minOut = d.amount + d.wbtcTopUp + d.minLoopWbtc - p.maxWbtcForUsds;
        uint256 returned = account.close(p);
        assertEq(returned, p.minOut);
        assertLe(wbtc.balanceOf(address(this)), ownerBefore);
        assertLe(ownerBefore - wbtc.balanceOf(address(this)), 2, "at most two WBTC minor units lost to rounding");
        assertEq(usds.balanceOf(address(morpho)), lenderBefore);
        assertEq(pool.debt(account.fxPositionId()), 0);
        assertEq(pool.collateral(account.fxPositionId()), 0);
        assertEq(cooler.debt(address(account)), 0);
        assertEq(cooler.collateral(address(account)), 0);
        assertTrue(account.closed());
        _assertEmpty(account);
    }
}
