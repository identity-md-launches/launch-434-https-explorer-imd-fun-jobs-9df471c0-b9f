// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenHandler is Test {
    LaunchToken public immutable token;
    address[4] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004)];
    uint256[4] public balances;
    mapping(uint256 => mapping(uint256 => uint256)) public approvals;

    constructor() {
        token = new LaunchToken();
        for (uint256 i; i < 4; ++i) {
            balances[i] = 1e27 / 4;
            token.transfer(actors[i], balances[i]);
        }
    }

    function transfer(uint256 sender, uint256 recipient, uint256 seed) external {
        sender %= 4;
        recipient %= 4;
        uint256 amount = bound(seed, 0, balances[sender]);
        vm.prank(actors[sender]);
        assertTrue(token.transfer(actors[recipient], amount));
        balances[sender] -= amount;
        balances[recipient] += amount;
    }

    function approve(uint256 owner, uint256 spender, uint256 amount, bool unlimited) external {
        owner %= 4;
        spender %= 4;
        amount = unlimited ? type(uint256).max : bound(amount, 0, 1e27);
        vm.prank(actors[owner]);
        assertTrue(token.approve(actors[spender], amount));
        approvals[owner][spender] = amount;
    }

    function transferFrom(uint256 owner, uint256 spender, uint256 recipient, uint256 seed) external {
        owner %= 4;
        spender %= 4;
        recipient %= 4;
        uint256 available = balances[owner];
        uint256 allowance = approvals[owner][spender];
        if (allowance < available) available = allowance;
        uint256 amount = bound(seed, 0, available);
        vm.prank(actors[spender]);
        assertTrue(token.transferFrom(actors[owner], actors[recipient], amount));
        if (allowance != type(uint256).max) approvals[owner][spender] -= amount;
        balances[owner] -= amount;
        balances[recipient] += amount;
    }

    function rejectedTransfer(uint256 sender, bool zeroRecipient) external {
        sender %= 4;
        address to = zeroRecipient ? address(0) : actors[(sender + 1) % 4];
        uint256 amount = zeroRecipient ? 0 : balances[sender] + 1;
        bytes memory errorData = zeroRecipient
            ? abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))
            : abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[sender], balances[sender], amount
            );
        vm.prank(actors[sender]);
        vm.expectRevert(errorData);
        token.transfer(to, amount);
    }

    function rejectedAllowanceSpend(uint256 owner, uint256 spender) external {
        owner %= 4;
        spender %= 4;
        uint256 allowance = approvals[owner][spender];
        if (allowance == type(uint256).max) return;
        vm.prank(actors[spender]);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, actors[spender], allowance, allowance + 1
            )
        );
        token.transferFrom(actors[owner], actors[spender], allowance + 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchTokenHandler handler;
    LaunchToken token;

    function setUp() public {
        handler = new LaunchTokenHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectedTransfer.selector;
        selectors[4] = handler.rejectedAllowanceSpend.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_fixedSupplyAndIndependentLedger() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = token.balanceOf(handler.actors(i));
            assertEq(balance, handler.balances(i), "transfer ledger");
            sum += balance;
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(handler.actors(i), handler.actors(j)), handler.approvals(i, j));
            }
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}

contract LaunchTokenEdgeTest is Test {
    function testZeroOneAndEntireSupplyRoundTrip() public {
        LaunchToken token = new LaunchToken();
        address user = address(0xCAFE);
        assertEq(token.decimals(), 18);
        assertTrue(token.transfer(user, 0));
        assertTrue(token.transfer(user, 1));
        assertTrue(token.transfer(user, 1e27 - 1));
        assertEq(token.balanceOf(user), 1e27);
        vm.prank(user);
        token.transfer(address(this), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.balanceOf(user), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function testRevertedTransferFromRestoresAllowanceAndBalances() public {
        LaunchToken token = new LaunchToken();
        address owner = address(0xCAFE);
        vm.prank(owner);
        token.approve(address(this), type(uint256).max - 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 0, 1));
        token.transferFrom(owner, address(this), 1);
        assertEq(token.allowance(owner, address(this)), type(uint256).max - 1);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testMaximumApprovalRemainsInfiniteAndRevocationTakesEffect() public {
        LaunchToken token = new LaunchToken();
        address spender = address(0xCAFE);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), spender, 1e27);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        token.approve(spender, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), spender, 1);
        assertEq(token.totalSupply(), 1e27);
    }
}
