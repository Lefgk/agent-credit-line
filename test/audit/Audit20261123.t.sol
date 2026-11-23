// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentCreditVault} from "../../src/AgentCreditVault.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";

/// @notice Audit 2026-11-23 PoCs / refutation tests. See AUDIT-2026-11-23.md.
contract Audit20261123Test is Test {
    AgentCreditVault vault;
    MockUSDC usdc;
    address owner = makeAddr("owner");
    address agentA = makeAddr("agentA");
    address agentB = makeAddr("agentB");
    address griefer = makeAddr("griefer");
    address shop = makeAddr("shop");
    uint64 constant MONTH = 30 days;
    uint128 constant CAP = 1_000e6;
    uint256 constant DEPOSIT = 10_000e6;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        vault = new AgentCreditVault(owner, address(usdc));
        usdc.mint(owner, 1_000_000e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(DEPOSIT);
        vault.openLine(agentA, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
        vault.openLine(agentB, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
        vault.setFeeBps(1_000);
        vm.stopPrank();
        address[3] memory who = [agentA, agentB, griefer];
        for (uint256 i; i < 3; i++) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    /// L-1: the public Record counters can be inflated with dust (by the agent or by anyone).
    function test_L1_recordCountersInflatableWithDust() public {
        vm.startPrank(agentA);
        for (uint256 i; i < 20; i++) {
            vault.borrow(agentA, 9, "dust"); // fee rounds to 0 at 10%
            vault.repay(agentA, 9);
        }
        vm.stopPrank();
        AgentCreditVault.Record memory r = vault.getRecord(agentA);
        assertEq(r.borrowCount, 20);
        assertEq(r.repayCount, 20);
        assertEq(r.totalBorrowed, 180); // 0.00018 USDC of "history"
        // a third party can also bump repayCount on someone else's open debt
        vm.prank(agentB);
        vault.borrow(shop, 100e6, "b");
        vm.startPrank(griefer);
        for (uint256 i; i < 5; i++) vault.repay(agentB, 1);
        vm.stopPrank();
        assertEq(vault.getRecord(agentB).repayCount, 5);
    }

    /// L-2: default can be stamped 1 second after dueDate (no grace) and the count is permanent.
    function test_L2_defaultOneSecondAfterDueIsPermanent() public {
        vm.prank(agentA);
        vault.borrow(shop, 100e6, "x");
        uint64 due = vault.getLine(agentA).dueDate;
        vm.warp(due + 1);
        vm.prank(griefer);
        vault.markDefault(agentA);
        vm.prank(agentA);
        vault.repay(agentA, type(uint256).max);
        vm.prank(owner);
        vault.clearDefault(agentA);
        assertEq(vault.getRecord(agentA).defaultCount, 1);
    }

    /// Refutation: the borrow window and the default window never overlap.
    function testFuzz_noBorrowAndDefaultInSameSecond(uint64 dt) public {
        vm.prank(agentA);
        vault.borrow(shop, 1e6, "x");
        dt = uint64(bound(dt, 0, 3 * MONTH));
        vm.warp(block.timestamp + dt);
        bool canBorrow;
        vm.prank(agentA);
        try vault.borrow(shop, 1e6, "y") { canBorrow = true; } catch {}
        bool canDefault;
        try vault.markDefault(agentA) { canDefault = true; } catch {}
        assertFalse(canBorrow && canDefault);
    }

    /// Info-1: fee is zero only when amount * bps < 10_000 (dust); debt never exceeds the cap.
    function testFuzz_feeRoundingAndCap(uint16 bps, uint256 amount) public {
        bps = uint16(bound(bps, 0, 1_000));
        amount = bound(amount, 1, CAP);
        vm.prank(owner);
        vault.setFeeBps(bps);
        (uint256 fee,) = vault.quote(amount);
        if (bps > 0 && amount * bps >= 10_000) assertGt(fee, 0);
        vm.prank(agentA);
        try vault.borrow(shop, amount, "f") {} catch {}
        assertLe(vault.amountDue(agentA), CAP);
    }

    /// Multi-agent accounting invariant: totals match per-line sums and USDC is conserved.
    function testFuzz_multiAgentAccounting(uint256 seed) public {
        uint256 feesPaid;
        for (uint256 i; i < 40; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address a = r & 1 == 0 ? agentA : agentB;
            uint256 op = (r >> 1) % 4;
            if (op == 0) {
                uint256 room = vault.availableCredit(a);
                if (room > 0) {
                    vm.prank(a);
                    vault.borrow(shop, bound(r >> 8, 1, room), "m");
                }
            } else if (op == 1) {
                uint256 due = vault.amountDue(a);
                if (due > 0) {
                    uint256 feeBefore = vault.getLine(a).feeOwed;
                    vm.prank(griefer);
                    vault.repay(a, bound(r >> 8, 1, due + 10));
                    feesPaid += feeBefore - vault.getLine(a).feeOwed;
                }
            } else if (op == 2) {
                vm.prank(owner);
                vault.setFeeBps(uint16(bound(r >> 8, 0, 1_000)));
            } else {
                vm.warp(block.timestamp + bound(r >> 8, 0, 3 days));
            }
        }
        AgentCreditVault.Line memory la = vault.getLine(agentA);
        AgentCreditVault.Line memory lb = vault.getLine(agentB);
        assertEq(vault.totalPrincipal(), uint256(la.principal) + lb.principal);
        assertEq(vault.totalFeeOwed(), uint256(la.feeOwed) + lb.feeOwed);
        assertEq(usdc.balanceOf(address(vault)), DEPOSIT - vault.totalPrincipal() + feesPaid);
        assertLe(uint256(la.principal) + la.feeOwed, la.maxBorrow);
        assertLe(uint256(lb.principal) + lb.feeOwed, lb.maxBorrow);
    }
}
