// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AgentCreditVault} from "../../src/AgentCreditVault.sol";
import {AgentCreditVaultFactory} from "../../src/AgentCreditVaultFactory.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @dev USDT-style token: transfer/transferFrom return no value.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external { allowance[msg.sender][s] = a; }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// @dev Fee-on-transfer token (1%). The vault is USDC-only, but deposit must report what it got.
contract FeeToken is MockUSDC {
    function _update(address from, address to, uint256 v) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = v / 100;
            super._update(from, address(0), fee);
            v -= fee;
        }
        super._update(from, to, v);
    }
}

contract Polish20261124Test is Test {
    AgentCreditVault vault;
    MockUSDC usdc;
    address owner = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address agent = makeAddr("agent");
    address other = makeAddr("other");
    address shop = makeAddr("shop");
    address rando = makeAddr("rando");
    uint64 constant MONTH = 30 days;
    uint128 constant CAP = 1_000e6;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        vault = new AgentCreditVault(owner, address(usdc));
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(agent, 1_000_000e6);
        usdc.mint(rando, 1_000_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
        vault.setGuardian(guardian);
        vm.stopPrank();
        vm.prank(agent);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(rando);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------- access control

    function test_onlyOwnerFunctionsRejectOthers() public {
        bytes4 sel = Ownable.OwnableUnauthorizedAccount.selector;
        address[3] memory callers = [rando, guardian, agent];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(sel, callers[i]));
            vault.withdraw(callers[i], 1);
            vm.expectRevert(abi.encodeWithSelector(sel, callers[i]));
            vault.setGuardian(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(sel, callers[i]));
            vault.setFeeBps(1);
            vm.expectRevert(abi.encodeWithSelector(sel, callers[i]));
            vault.openLine(callers[i], 1, uint64(block.timestamp + 10), uint64(block.timestamp + 10), false);
            vm.expectRevert(abi.encodeWithSelector(sel, callers[i]));
            vault.setRecipient(agent, shop, true);
            vm.expectRevert(abi.encodeWithSelector(sel, callers[i]));
            vault.clearDefault(agent);
            vm.expectRevert(abi.encodeWithSelector(sel, callers[i]));
            vault.unpause();
            vm.stopPrank();
        }
    }

    function test_revokeAndPauseRejectStrangers() public {
        vm.startPrank(rando);
        vm.expectRevert(AgentCreditVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);
        vm.expectRevert(AgentCreditVault.NotOwnerOrGuardian.selector);
        vault.pause();
        vm.stopPrank();
        assertTrue(vault.getLine(agent).active);
    }

    function test_guardianCanPauseButNotUnpause() public {
        vm.prank(guardian);
        vault.pause();
        assertTrue(vault.paused());
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_unsetGuardianLosesPowers() public {
        vm.prank(owner);
        vault.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(AgentCreditVault.NotOwnerOrGuardian.selector);
        vault.pause();
        // zero address can never act as guardian: nobody has msg.sender == 0
        assertEq(vault.guardian(), address(0));
    }

    function test_ownable2StepTransfer() public {
        vm.prank(owner);
        vault.transferOwnership(other);
        assertEq(vault.owner(), owner); // not yet
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        vault.acceptOwnership();
        vm.prank(other);
        vault.acceptOwnership();
        assertEq(vault.owner(), other);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vault.setFeeBps(5);
    }

    function test_constructorRejectsZeroUsdc() public {
        vm.expectRevert(AgentCreditVault.ZeroAddress.selector);
        new AgentCreditVault(owner, address(0));
    }

    function test_renounceByNonAgentReverts() public {
        vm.prank(rando);
        vm.expectRevert(AgentCreditVault.NotAgent.selector);
        vault.renounceAgent();
        vm.prank(agent);
        vault.renounceAgent();
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.NotAgent.selector);
        vault.renounceAgent(); // already inactive
    }

    // ---------------------------------------------------------------- time boundaries

    function test_borrowBoundaryAtExpiryAndDue() public {
        uint64 expiry = vault.getLine(agent).expiry;
        vm.warp(expiry - 1);
        vm.prank(agent);
        vault.borrow(shop, 1e6, "ok");
        vm.warp(expiry);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.AgentExpired.selector);
        vault.borrow(shop, 1e6, "late");
    }

    function test_borrowAtDueWhenExpiryEqualsDue() public {
        vm.startPrank(owner);
        vault.openLine(other, CAP, uint64(block.timestamp + 100), uint64(block.timestamp + 100), false);
        vm.stopPrank();
        vm.warp(block.timestamp + 100);
        vm.prank(other);
        vm.expectRevert(AgentCreditVault.AgentExpired.selector);
        vault.borrow(shop, 1, "x");
    }

    function test_markDefaultBoundaryExactlyAtDueReverts() public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "x");
        uint64 due = vault.getLine(agent).dueDate;
        vm.warp(due);
        vm.expectRevert(AgentCreditVault.NotDue.selector);
        vault.markDefault(agent);
        vm.warp(due + 1);
        vault.markDefault(agent);
        vm.expectRevert(AgentCreditVault.AlreadyDefaulted.selector);
        vault.markDefault(agent);
        AgentCreditVault.Record memory r = vault.getRecord(agent);
        assertEq(r.defaultCount, 1);
        assertEq(r.lastDefaultAt, due + 1);
    }

    function test_defaultedAgentCannotBorrowEvenIfRepaidUntilCleared() public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "x");
        vm.warp(vault.getLine(agent).dueDate + 1);
        vault.markDefault(agent);
        vm.prank(rando);
        vault.repay(agent, type(uint256).max); // third party clears the debt
        assertEq(vault.amountDue(agent), 0);
        assertEq(vault.availableCredit(agent), 0);
        // owner extends window; zero debt + openLine clears default
        vm.prank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + MONTH), false);
        assertFalse(vault.getLine(agent).defaulted);
        vm.prank(agent);
        vault.borrow(shop, 1e6, "again");
    }

    function test_openLineKeepsDefaultWhenDebtRemains() public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "x");
        vm.warp(vault.getLine(agent).dueDate + 1);
        vault.markDefault(agent);
        vm.prank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + MONTH), false);
        assertTrue(vault.getLine(agent).defaulted);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.LineDefaulted.selector);
        vault.borrow(shop, 1e6, "x");
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.DebtOutstanding.selector);
        vault.clearDefault(agent);
    }

    // ---------------------------------------------------------------- revoke / repay / epoch

    function test_repayAllowedWhilePausedRevokedDefaulted() public {
        vm.prank(agent);
        vault.borrow(shop, 100e6, "x");
        vm.prank(owner);
        vault.pause();
        vm.prank(guardian);
        vault.revokeAgent(agent);
        vm.warp(vault.getLine(agent).dueDate + 1);
        vault.markDefault(agent); // markDefault works while paused/revoked
        vm.prank(agent);
        vault.repay(agent, 40e6);
        vm.prank(rando);
        vault.repay(agent, 60e6);
        assertEq(vault.amountDue(agent), 0);
        assertEq(vault.totalPrincipal(), 0);
    }

    function test_reopenAfterRevokeNeedsFreshAllowlist() public {
        vm.startPrank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + MONTH), true);
        vault.setRecipient(agent, shop, true);
        vault.revokeAgent(agent);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + MONTH), true);
        vm.stopPrank();
        assertFalse(vault.isRecipientAllowed(agent, shop));
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.RecipientNotAllowed.selector);
        vault.borrow(shop, 1e6, "x");
    }

    function test_allowlistRevokeRecipientAndZeroRecipient() public {
        vm.startPrank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + MONTH), true);
        vm.expectRevert(AgentCreditVault.ZeroAddress.selector);
        vault.setRecipient(agent, address(0), true);
        vault.setRecipient(agent, shop, true);
        vault.setRecipient(agent, shop, false);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.RecipientNotAllowed.selector);
        vault.borrow(shop, 1e6, "x");
    }

    function test_revokedDebtStillCountsAndBorrowBlocked() public {
        vm.prank(agent);
        vault.borrow(shop, 100e6, "x");
        vm.prank(owner);
        vault.revokeAgent(agent);
        assertEq(vault.availableCredit(agent), 0);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.NotAgent.selector);
        vault.borrow(shop, 1, "x");
        assertEq(vault.amountDue(agent), 100e6);
    }

    function test_borrowZeroToAndZeroAmount() public {
        vm.startPrank(agent);
        vm.expectRevert(AgentCreditVault.ZeroAddress.selector);
        vault.borrow(address(0), 1, "x");
        vm.expectRevert(AgentCreditVault.ZeroAmount.selector);
        vault.borrow(shop, 0, "x");
        vm.expectRevert(AgentCreditVault.ZeroAmount.selector);
        vault.repay(agent, 0);
        vm.stopPrank();
    }

    function test_borrowMaxAmountReverts() public {
        vm.prank(agent);
        vm.expectRevert(); // overflow in newDebt or ExceedsCredit; never succeeds
        vault.borrow(shop, type(uint256).max, "x");
        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, type(uint256).max - 1, "x");
    }

    function test_feeWithMaxFeeBpsExactCapFill() public {
        vm.prank(owner);
        vault.setFeeBps(1_000);
        uint256 room = vault.availableCredit(agent);
        assertEq(room, (uint256(CAP) * 10_000) / 11_000);
        vm.prank(agent);
        vault.borrow(shop, room, "max");
        assertLe(vault.amountDue(agent), CAP);
        assertEq(vault.availableCredit(agent), 0);
        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, 1e6, "more");
    }

    function test_repayPaysFeeFirstThenPrincipal() public {
        vm.prank(owner);
        vault.setFeeBps(1_000);
        vm.prank(agent);
        vault.borrow(shop, 100e6, "x"); // fee 10e6
        vm.prank(rando);
        vault.repay(agent, 10e6);
        AgentCreditVault.Line memory l = vault.getLine(agent);
        assertEq(l.feeOwed, 0);
        assertEq(l.principal, 100e6);
        assertEq(vault.totalFeeOwed(), 0);
        assertEq(vault.totalPrincipal(), 100e6);
    }

    function test_feeChangeDoesNotAffectExistingDebt() public {
        vm.prank(owner);
        vault.setFeeBps(500);
        vm.prank(agent);
        vault.borrow(shop, 100e6, "x");
        vm.prank(owner);
        vault.setFeeBps(1_000);
        assertEq(vault.amountDue(agent), 105e6);
    }

    function test_withdrawCanDrainAndBorrowThenInsufficient() public {
        vm.prank(owner);
        vault.withdraw(owner, 10_000e6);
        assertEq(vault.availableCredit(agent), 0);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.InsufficientLiquidity.selector);
        vault.borrow(shop, 1, "x");
        vm.prank(owner);
        vm.expectRevert(); // nothing left
        vault.withdraw(owner, 1);
    }

    function test_withdrawToZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.ZeroAddress.selector);
        vault.withdraw(address(0), 1);
    }

    // ---------------------------------------------------------------- events

    function test_eventsEmitted() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit AgentCreditVault.Borrowed(agent, shop, 5e6, 0, 5e6, "memo");
        vm.prank(agent);
        vault.borrow(shop, 5e6, "memo");

        vm.expectEmit(true, true, false, true, address(vault));
        emit AgentCreditVault.Repaid(agent, rando, 2e6, 3e6);
        vm.prank(rando);
        vault.repay(agent, 2e6);

        vm.expectEmit(true, true, false, true, address(vault));
        emit AgentCreditVault.AgentRevoked(agent, guardian, 1);
        vm.prank(guardian);
        vault.revokeAgent(agent);
    }

    // ---------------------------------------------------------------- tokens

    function test_noReturnTokenWorks() public {
        NoReturnToken t = new NoReturnToken();
        AgentCreditVault v = new AgentCreditVault(owner, address(t));
        t.mint(owner, 1_000e6);
        t.mint(agent, 1_000e6);
        vm.startPrank(owner);
        t.approve(address(v), type(uint256).max);
        v.deposit(1_000e6);
        v.openLine(agent, 500e6, uint64(block.timestamp + MONTH), uint64(block.timestamp + MONTH), false);
        vm.stopPrank();
        vm.startPrank(agent);
        t.approve(address(v), type(uint256).max);
        v.borrow(shop, 100e6, "x");
        v.repay(agent, 100e6);
        vm.stopPrank();
        assertEq(v.totalPrincipal(), 0);
        assertEq(t.balanceOf(address(v)), 1_000e6);
    }

    function test_depositEventReportsActualReceivedForFeeToken() public {
        FeeToken t = new FeeToken();
        AgentCreditVault v = new AgentCreditVault(owner, address(t));
        t.mint(owner, 1_000e6);
        vm.startPrank(owner);
        t.approve(address(v), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(v));
        emit AgentCreditVault.Deposited(owner, 990e6);
        v.deposit(1_000e6);
        vm.stopPrank();
        assertEq(t.balanceOf(address(v)), 990e6);
    }

    function test_usdcMockIsSixDecimals() public view {
        assertEq(usdc.decimals(), 6);
    }

    // ---------------------------------------------------------------- factory

    function test_factoryMultipleVaultsPerOwnerIndependent() public {
        AgentCreditVaultFactory f = new AgentCreditVaultFactory(address(usdc));
        vm.startPrank(other);
        address v1 = f.createVault();
        address v2 = f.createVault();
        vm.stopPrank();
        assertTrue(v1 != v2);
        address[] memory list = f.vaultsOf(other);
        assertEq(list.length, 2);
        assertEq(AgentCreditVault(v1).owner(), other);
        assertEq(AgentCreditVault(v2).owner(), other);
        assertEq(f.vaultsOf(rando).length, 0);
        // state independence
        vm.prank(other);
        AgentCreditVault(v1).setFeeBps(50);
        assertEq(AgentCreditVault(v2).feeBps(), 0);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_borrowRepayRoundTripRestoresState(uint16 bps, uint256 amt, uint256 extra) public {
        bps = uint16(bound(bps, 0, 1_000));
        vm.prank(owner);
        vault.setFeeBps(bps);
        uint256 room = vault.availableCredit(agent);
        amt = bound(amt, 1, room);
        vm.prank(agent);
        vault.borrow(shop, amt, "f");
        uint256 due = vault.amountDue(agent);
        assertLe(due, CAP);
        extra = bound(extra, 0, type(uint128).max);
        vm.prank(rando);
        vault.repay(agent, due + extra); // overpay capped
        assertEq(vault.amountDue(agent), 0);
        assertEq(vault.totalPrincipal(), 0);
        assertEq(vault.totalFeeOwed(), 0);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6 + (due - amt));
    }

    function testFuzz_availableCreditAlwaysBorrowable(uint16 bps, uint256 depositedSeed) public {
        bps = uint16(bound(bps, 0, 1_000));
        vm.prank(owner);
        vault.setFeeBps(bps);
        uint256 withdrawAmt = bound(depositedSeed, 0, 10_000e6 - 1);
        if (withdrawAmt > 0) {
            vm.prank(owner);
            vault.withdraw(owner, withdrawAmt);
        }
        uint256 room = vault.availableCredit(agent);
        if (room == 0) return;
        vm.prank(agent);
        vault.borrow(shop, room, "x"); // must not revert
        // and one more unit would have exceeded either cap or liquidity
        (uint256 fee,) = vault.quote(1);
        uint256 debt = vault.amountDue(agent);
        assertTrue(debt + 1 + fee > CAP || usdc.balanceOf(address(vault)) == 0 || vault.availableCredit(agent) <= 1);
    }

    function testFuzz_strangerCannotBorrow(address caller, uint256 amt) public {
        vm.assume(caller != agent);
        amt = bound(amt, 1, 1e6);
        vm.prank(caller);
        vm.expectRevert(AgentCreditVault.NotAgent.selector);
        vault.borrow(shop, amt, "x");
    }
}
