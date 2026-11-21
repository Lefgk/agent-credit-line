// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentCreditVault} from "../src/AgentCreditVault.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract Handler is Test {
    AgentCreditVault public vault;
    MockUSDC public usdc;
    address public owner;
    address public agent;
    address[] public recipients;
    address public outsider = makeAddr("outsider-not-allowlisted");
    address public payer = makeAddr("handler-payer");

    uint128 public constant CAP = 5_000e6;

    uint256 public ghostMaxDebt;
    uint256 public ghostBorrowed;
    uint256 public ghostRepaid;
    uint256 public ghostOutsiderReceived;
    uint256 public ghostBorrowsWhileBlocked;
    uint256 public ghostOverCollect;
    uint256 public calls;

    constructor(AgentCreditVault v, MockUSDC u, address o, address a, address[] memory r) {
        vault = v;
        usdc = u;
        owner = o;
        agent = a;
        recipients = r;
        usdc.mint(payer, 10_000_000e6);
        vm.prank(payer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function borrow(uint256 amt, uint256 rIdx) external {
        calls++;
        amt = bound(amt, 1, 6_000e6);
        address to = rIdx % 8 == 0 ? outsider : recipients[rIdx % recipients.length];
        AgentCreditVault.Line memory line = vault.getLine(agent);
        bool blocked = !line.active || line.defaulted || vault.paused() || block.timestamp >= line.expiry
            || block.timestamp >= line.dueDate;
        uint256 debtBefore = vault.amountDue(agent);
        vm.prank(agent);
        try vault.borrow(to, amt, bytes32(calls)) {
            if (blocked) ghostBorrowsWhileBlocked++;
            if (to == outsider) ghostOutsiderReceived += amt;
            ghostBorrowed += amt;
            uint256 debt = vault.amountDue(agent);
            if (debt > ghostMaxDebt) ghostMaxDebt = debt;
            if (debt > CAP) ghostMaxDebt = debt; // recorded; invariant asserts <= CAP
            assertGe(debt, debtBefore);
        } catch {}
    }

    function repay(uint256 amt) external {
        amt = bound(amt, 1, 10_000e6);
        uint256 debt = vault.amountDue(agent);
        if (debt == 0) return;
        uint256 before = usdc.balanceOf(payer);
        vm.prank(payer);
        try vault.repay(agent, amt) {
            uint256 taken = before - usdc.balanceOf(payer);
            ghostRepaid += taken;
            if (taken > debt) ghostOverCollect++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
    }

    function togglePause(bool p) external {
        bool isPaused = vault.paused();
        vm.prank(owner);
        if (p && !isPaused) vault.pause();
        else if (!p && isPaused) vault.unpause();
        else vault.owner();
    }

    function revokeAndReopen(bool reopen) external {
        vm.startPrank(owner);
        vault.revokeAgent(agent);
        if (reopen) {
            uint256 debt = vault.amountDue(agent);
            uint128 cap = debt > CAP ? uint128(debt) : CAP;
            if (block.timestamp >= type(uint64).max - 120 days) {
                vm.stopPrank();
                return;
            }
            vault.openLine(agent, cap, uint64(block.timestamp + 60 days), uint64(block.timestamp + 120 days), true);
            for (uint256 i; i < recipients.length; i++) {
                vault.setRecipient(agent, recipients[i], true);
            }
        }
        vm.stopPrank();
    }

    function maybeMarkDefault() external {
        try vault.markDefault(agent) {} catch {}
    }

    function maybeClearDefault() external {
        vm.prank(owner);
        try vault.clearDefault(agent) {} catch {}
    }

    function setFee(uint16 bps) external {
        bps = uint16(bound(bps, 0, vault.MAX_FEE_BPS()));
        vm.prank(owner);
        vault.setFeeBps(bps);
    }

}

contract AgentCreditVaultInvariantTest is Test {
    AgentCreditVault vault;
    MockUSDC usdc;
    Handler handler;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    uint256 constant FUND = 1_000_000e6;
    uint256 vaultUsdc0;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        vault = new AgentCreditVault(owner, address(usdc));
        address[] memory r = new address[](3);
        r[0] = makeAddr("r0");
        r[1] = makeAddr("r1");
        r[2] = makeAddr("r2");

        usdc.mint(owner, FUND);
        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(FUND);
        vault.openLine(agent, handlerCap(), uint64(block.timestamp + 365 days), uint64(block.timestamp + 400 days), true);
        for (uint256 i; i < r.length; i++) {
            vault.setRecipient(agent, r[i], true);
        }
        vm.stopPrank();

        handler = new Handler(vault, usdc, owner, agent, r);

        vaultUsdc0 = usdc.balanceOf(address(vault));
        targetContract(address(handler));
        address fuzzCaller = makeAddr("fuzz-caller");
        vm.deal(fuzzCaller, 1_000 ether);
        targetSender(fuzzCaller);
    }

    function handlerCap() internal pure returns (uint128) {
        return 5_000e6;
    }

    function invariant_debtNeverExceedsCap() public view {
        assertLe(vault.amountDue(agent), vault.getLine(agent).maxBorrow);
        assertLe(handler.ghostMaxDebt(), vault.getLine(agent).maxBorrow);
    }

    function invariant_totalsMatchLine() public view {
        AgentCreditVault.Line memory line = vault.getLine(agent);
        assertEq(vault.totalPrincipal(), line.principal);
        assertEq(vault.totalFeeOwed(), line.feeOwed);
        assertEq(vault.amountDue(agent), uint256(line.principal) + line.feeOwed);
    }

    function invariant_accountingMatchesBalances() public view {
        // vault = initial + repayments - borrows (fees stay in the vault once repaid)
        assertEq(usdc.balanceOf(address(vault)), vaultUsdc0 + handler.ghostRepaid() - handler.ghostBorrowed());
    }

    function invariant_neverPaysOutsider() public view {
        assertEq(handler.ghostOutsiderReceived(), 0);
        assertEq(usdc.balanceOf(handler.outsider()), 0);
    }

    function invariant_noBorrowWhileBlocked() public view {
        assertEq(handler.ghostBorrowsWhileBlocked(), 0);
    }

    function invariant_repayNeverOverCollects() public view {
        assertEq(handler.ghostOverCollect(), 0);
        assertLe(handler.ghostRepaid(), handler.ghostBorrowed() + vault.totalFeeOwed() + vault.getRecord(agent).totalRepaid);
        // repaid cannot exceed borrowed principal + fees charged (which equal totalRepaid + remaining fee if mid-repay)
        assertLe(handler.ghostRepaid(), handler.ghostBorrowed() + (handler.ghostBorrowed() * vault.MAX_FEE_BPS()) / 10_000);
    }

    function invariant_lifetimeRecordConsistent() public view {
        AgentCreditVault.Line memory line = vault.getLine(agent);
        AgentCreditVault.Record memory rec = vault.getRecord(agent);
        assertEq(rec.totalBorrowed, handler.ghostBorrowed());
        assertEq(rec.totalRepaid, handler.ghostRepaid());
        assertGe(rec.totalBorrowed, line.principal);
    }
}
