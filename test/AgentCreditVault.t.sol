// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentCreditVault} from "../src/AgentCreditVault.sol";
import {AgentCreditVaultFactory} from "../src/AgentCreditVaultFactory.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract AgentCreditVaultTest is Test {
    AgentCreditVault vault;
    MockUSDC usdc;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address stranger = makeAddr("stranger");
    address guardian = makeAddr("guardian");
    address payer = makeAddr("payer");

    uint64 constant MONTH = 30 days;
    uint128 constant CAP = 1_000e6;

    event Borrowed(
        address indexed agent,
        address indexed to,
        uint256 amount,
        uint256 fee,
        uint256 debt,
        bytes32 memo
    );
    event Repaid(address indexed agent, address indexed from, uint256 amount, uint256 remainingDebt);
    event Defaulted(address indexed agent, uint256 debt, address indexed by);

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        vault = new AgentCreditVault(owner, address(usdc));
        usdc.mint(owner, 1_000_000e6);
        usdc.mint(payer, 1_000_000e6);
        usdc.mint(agent, 1_000_000e6);

        vm.startPrank(owner);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
        vm.stopPrank();

        vm.prank(payer);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(agent);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _line() internal view returns (AgentCreditVault.Line memory) {
        return vault.getLine(agent);
    }

    function _record() internal view returns (AgentCreditVault.Record memory) {
        return vault.getRecord(agent);
    }

    // ---------------------------------------------------------------- happy paths

    function test_borrowAndRepayNoFee() public {
        vm.expectEmit(true, true, false, true);
        emit Borrowed(agent, shop, 100e6, 0, 100e6, "job-1");
        vm.prank(agent);
        vault.borrow(shop, 100e6, "job-1");
        assertEq(usdc.balanceOf(shop), 100e6);
        assertEq(vault.amountDue(agent), 100e6);
        assertEq(vault.totalPrincipal(), 100e6);
        assertEq(_record().borrowCount, 1);
        assertEq(_record().totalBorrowed, 100e6);

        vm.expectEmit(true, true, false, true);
        emit Repaid(agent, payer, 40e6, 60e6);
        vm.prank(payer);
        vault.repay(agent, 40e6);
        assertEq(vault.amountDue(agent), 60e6);

        vm.prank(agent);
        vault.repay(agent, 60e6);
        assertEq(vault.amountDue(agent), 0);
        assertEq(vault.totalPrincipal(), 0);
        assertEq(_record().totalRepaid, 100e6);
        assertEq(_record().repayCount, 2);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6);
    }

    function test_flatFeeAddedToDebtAndRepaidFirst() public {
        vm.prank(owner);
        vault.setFeeBps(100); // 1%
        (uint256 fee, uint256 delta) = vault.quote(100e6);
        assertEq(fee, 1e6);
        assertEq(delta, 101e6);

        vm.prank(agent);
        vault.borrow(shop, 100e6, "fee");
        assertEq(usdc.balanceOf(shop), 100e6);
        assertEq(vault.amountDue(agent), 101e6);
        assertEq(_line().principal, 100e6);
        assertEq(_line().feeOwed, 1e6);
        assertEq(vault.totalFeeOwed(), 1e6);

        // repay 1.5 USDC: 1 fee + 0.5 principal
        vm.prank(payer);
        vault.repay(agent, 1.5e6);
        assertEq(_line().feeOwed, 0);
        assertEq(_line().principal, 99.5e6);
        assertEq(vault.totalFeeOwed(), 0);
        assertEq(vault.totalPrincipal(), 99.5e6);

        vm.prank(payer);
        vault.repay(agent, 99.5e6);
        assertEq(vault.amountDue(agent), 0);
        // vault started 10_000, sent 100, received 101 fee+principal
        assertEq(usdc.balanceOf(address(vault)), 10_001e6);
    }

    function test_availableCreditAccountsForFeeAndLiquidity() public {
        vm.prank(owner);
        vault.setFeeBps(100);
        // room 1000, fee 1% => P + 0.01P <= 1000 => P <= 1000 / 1.01
        uint256 credit = vault.availableCredit(agent);
        assertEq(credit, (uint256(CAP) * 10_000) / 10_100);
        vm.prank(agent);
        vault.borrow(shop, credit, "max");
        assertLe(vault.amountDue(agent), CAP);
        assertEq(vault.availableCredit(agent), 0);
    }

    function test_optionalAllowlistOffAllowsAnyDestination() public {
        vm.prank(agent);
        vault.borrow(stranger, 10e6, "open");
        assertEq(usdc.balanceOf(stranger), 10e6);
    }

    function test_allowlistOnBlocksUnknownRecipient() public {
        vm.startPrank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.RecipientNotAllowed.selector);
        vault.borrow(stranger, 10e6, "no");

        vm.prank(agent);
        vault.borrow(shop, 10e6, "yes");
        assertEq(usdc.balanceOf(shop), 10e6);
    }

    function test_revokeWipesAllowlistAndBlocksBorrowButKeepsDebt() public {
        vm.startPrank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        vm.prank(agent);
        vault.borrow(shop, 50e6, "x");

        vm.prank(owner);
        vault.revokeAgent(agent);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.NotAgent.selector);
        vault.borrow(shop, 1e6, "y");
        assertEq(vault.amountDue(agent), 50e6);
        assertFalse(vault.isRecipientAllowed(agent, shop));

        // re-open: allowlist must be set again; debt still counts against the cap
        vm.startPrank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        vm.prank(agent);
        vault.borrow(shop, 10e6, "again");
        assertEq(vault.amountDue(agent), 60e6);
    }

    function test_renounceAndGuardianRevoke() public {
        vm.prank(owner);
        vault.setGuardian(guardian);
        vm.prank(agent);
        vault.renounceAgent();
        assertFalse(_line().active);

        vm.startPrank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
        vm.stopPrank();
        vm.prank(guardian);
        vault.revokeAgent(agent);
        assertFalse(_line().active);

        vm.prank(stranger);
        vm.expectRevert(AgentCreditVault.NotOwnerOrGuardian.selector);
        vault.revokeAgent(agent);
    }

    function test_pauseBlocksBorrowAllowsRepayAndWithdraw() public {
        vm.prank(agent);
        vault.borrow(shop, 100e6, "p");
        vm.prank(guardian); // not set yet
        vm.expectRevert(AgentCreditVault.NotOwnerOrGuardian.selector);
        vault.pause();

        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.borrow(shop, 1e6, "no");

        vm.prank(payer);
        vault.repay(agent, 100e6);
        assertEq(vault.amountDue(agent), 0);

        uint256 before = usdc.balanceOf(owner);
        vm.prank(owner);
        vault.withdraw(owner, 1_000e6);
        assertEq(usdc.balanceOf(owner), before + 1_000e6);

        vm.prank(stranger);
        vm.expectRevert();
        vault.unpause();
        vm.prank(owner);
        vault.unpause();
        vm.prank(agent);
        vault.borrow(shop, 1e6, "ok");
    }

    function test_markDefaultAfterDueDateAndClearAfterRepay() public {
        vm.prank(agent);
        vault.borrow(shop, 200e6, "d");

        vm.prank(stranger);
        vm.expectRevert(AgentCreditVault.NotDue.selector);
        vault.markDefault(agent);

        vm.warp(_line().dueDate + 1);
        vm.expectEmit(true, true, false, true);
        emit Defaulted(agent, 200e6, stranger);
        vm.prank(stranger);
        vault.markDefault(agent);
        assertTrue(_line().defaulted);
        assertEq(_record().defaultCount, 1);

        vm.prank(stranger);
        vm.expectRevert(AgentCreditVault.AlreadyDefaulted.selector);
        vault.markDefault(agent);

        // even if we re-open with a future due date, default blocks borrow
        vm.prank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
        assertTrue(_line().defaulted);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.LineDefaulted.selector);
        vault.borrow(shop, 1e6, "blocked");

        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.DebtOutstanding.selector);
        vault.clearDefault(agent);

        vm.prank(payer);
        vault.repay(agent, 200e6);
        vm.prank(owner);
        vault.clearDefault(agent);
        assertFalse(_line().defaulted);
        vm.prank(agent);
        vault.borrow(shop, 1e6, "reinstated");
    }

    function test_openLineWithZeroDebtClearsDefault() public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "x");
        vm.warp(_line().dueDate + 1);
        vault.markDefault(agent);
        vm.prank(payer);
        vault.repay(agent, 10e6);
        vm.prank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
        assertFalse(_line().defaulted);
        // lifetime record is kept
        assertEq(_record().defaultCount, 1);
        assertEq(_record().totalBorrowed, 10e6);
        assertEq(_record().totalRepaid, 10e6);
    }

    function test_borrowBlockedAfterExpiryAndDueDate() public {
        uint64 expiry = uint64(block.timestamp + 7 days);
        uint64 due = uint64(block.timestamp + 14 days);
        vm.prank(owner);
        vault.openLine(agent, CAP, expiry, due, false);

        vm.warp(expiry);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.AgentExpired.selector);
        vault.borrow(shop, 1e6, "e");

        // line with due == expiry already fails on expiry first; open a line where due is soon
        vm.warp(1_700_000_000);
        vm.prank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + 20 days), uint64(block.timestamp + 20 days), false);
        // can't set due < expiry
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.InvalidExpiry.selector);
        vault.openLine(agent, CAP, uint64(block.timestamp + 20 days), uint64(block.timestamp + 19 days), false);
    }

    function test_exceedsCreditAndInsufficientLiquidity() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentCreditVault.ExceedsCredit.selector, CAP + 1, CAP));
        vault.borrow(shop, CAP + 1, "big");

        // drain unused liquidity, leave less than a borrow
        vm.prank(owner);
        vault.withdraw(owner, 10_000e6 - 50e6);
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.InsufficientLiquidity.selector);
        vault.borrow(shop, 51e6, "liq");
        vm.prank(agent);
        vault.borrow(shop, 50e6, "ok");
    }

    function test_repayCapsOverpaymentAndRevertsIfNoDebt() public {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "x");
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        vault.repay(agent, 50e6);
        assertEq(usdc.balanceOf(payer), payerBefore - 10e6);
        assertEq(vault.amountDue(agent), 0);
        vm.prank(payer);
        vm.expectRevert(AgentCreditVault.NoDebt.selector);
        vault.repay(agent, 1);
    }

    function test_capCannotGoBelowDebt() public {
        vm.prank(agent);
        vault.borrow(shop, 400e6, "x");
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.CapBelowDebt.selector);
        vault.openLine(agent, 399e6, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), false);
    }

    function test_depositAnyoneWithdrawOwnerOnly() public {
        usdc.mint(stranger, 5e6);
        vm.startPrank(stranger);
        usdc.approve(address(vault), 5e6);
        vault.deposit(5e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.withdraw(stranger, 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(vault)), 10_005e6);
    }

    function test_setFeeBpsCapAndZeroAddressGuards() public {
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.InvalidFee.selector);
        vault.setFeeBps(1_001);
        vm.prank(owner);
        vault.setFeeBps(1_000);
        assertEq(vault.feeBps(), 1_000);

        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.ZeroAddress.selector);
        vault.openLine(address(0), CAP, uint64(block.timestamp + 1), uint64(block.timestamp + 1), false);

        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.InvalidLine.selector);
        vault.openLine(agent, 0, uint64(block.timestamp + 1), uint64(block.timestamp + 1), false);

        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.ZeroAddress.selector);
        vault.borrow(address(0), 1, "");
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.ZeroAmount.selector);
        vault.borrow(shop, 0, "");
    }

    function test_factoryCreatesOwnerVaultPinnedToUsdc() public {
        AgentCreditVaultFactory factory = new AgentCreditVaultFactory(address(usdc));
        vm.prank(owner);
        address v = factory.createVault();
        assertEq(AgentCreditVault(v).owner(), owner);
        assertEq(address(AgentCreditVault(v).usdc()), address(usdc));
        assertEq(factory.vaultsOf(owner).length, 1);
        assertEq(factory.vaultsOf(owner)[0], v);
    }

    function test_factoryRejectsZeroUsdc() public {
        vm.expectRevert(AgentCreditVaultFactory.ZeroAddress.selector);
        new AgentCreditVaultFactory(address(0));
    }

    function test_zeroAmountDepositAndWithdrawRevert() public {
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.ZeroAmount.selector);
        vault.withdraw(owner, 0);
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.ZeroAddress.selector);
        vault.withdraw(address(0), 1);
    }

    function test_clearDefaultWhenNotDefaultedReverts() public {
        vm.prank(owner);
        vm.expectRevert(AgentCreditVault.NotDefaulted.selector);
        vault.clearDefault(agent);
    }

    function test_markDefaultWithNoDebtReverts() public {
        vm.warp(_line().dueDate + 1);
        vm.expectRevert(AgentCreditVault.NoDebt.selector);
        vault.markDefault(agent);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_borrowRespectsCap(uint256 a1, uint256 a2, uint256 a3) public {
        uint256[3] memory amts = [bound(a1, 1, CAP + 100e6), bound(a2, 1, CAP + 100e6), bound(a3, 1, CAP + 100e6)];
        uint256 debt;
        for (uint256 i; i < 3; i++) {
            vm.prank(agent);
            try vault.borrow(shop, amts[i], bytes32(i)) {
                debt += amts[i];
            } catch {}
        }
        assertLe(debt, CAP);
        assertEq(vault.amountDue(agent), debt);
        assertEq(usdc.balanceOf(shop), debt);
    }

    function testFuzz_feeMath(uint16 bps, uint256 amount) public {
        bps = uint16(bound(bps, 0, vault.MAX_FEE_BPS()));
        amount = bound(amount, 1, 100_000e6);
        vm.prank(owner);
        vault.setFeeBps(bps);
        (uint256 fee, uint256 delta) = vault.quote(amount);
        assertEq(fee, (amount * bps) / 10_000);
        assertEq(delta, amount + fee);
    }

    function testFuzz_repayNeverOverCollects(uint256 borrowAmt, uint256 repayAmt) public {
        borrowAmt = bound(borrowAmt, 1, CAP);
        repayAmt = bound(repayAmt, 1, 10 * uint256(CAP));
        vm.prank(agent);
        vault.borrow(shop, borrowAmt, "f");
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        vault.repay(agent, repayAmt);
        uint256 taken = payerBefore - usdc.balanceOf(payer);
        assertLe(taken, borrowAmt);
        assertEq(taken + vault.amountDue(agent), borrowAmt);
    }

    function testFuzz_nonAgentCannotBorrow(address caller) public {
        vm.assume(caller != agent);
        vm.prank(caller);
        vm.expectRevert(AgentCreditVault.NotAgent.selector);
        vault.borrow(shop, 1e6, bytes32(0));
    }

    function testFuzz_expiryEnforced(uint64 dt) public {
        dt = uint64(bound(dt, 0, 400 days));
        vm.warp(block.timestamp + dt);
        vm.prank(agent);
        if (dt >= MONTH) {
            // expiry is +30 days, due is +60 days
            if (dt >= MONTH) vm.expectRevert(AgentCreditVault.AgentExpired.selector);
        }
        vault.borrow(shop, 1e6, bytes32(0));
    }

    function testFuzz_allowlistEnforced(address to) public {
        vm.assume(to != shop && to != address(0));
        vm.startPrank(owner);
        vault.openLine(agent, CAP, uint64(block.timestamp + MONTH), uint64(block.timestamp + 2 * MONTH), true);
        vault.setRecipient(agent, shop, true);
        vm.stopPrank();
        vm.prank(agent);
        vm.expectRevert(AgentCreditVault.RecipientNotAllowed.selector);
        vault.borrow(to, 1e6, bytes32(0));
    }

    function testFuzz_openLineValidation(uint128 cap, uint64 expiryOff, uint64 dueOff) public {
        expiryOff = uint64(bound(expiryOff, 0, 365 days));
        dueOff = uint64(bound(dueOff, 0, 365 days));
        uint64 expiry = uint64(block.timestamp) + expiryOff;
        uint64 due = uint64(block.timestamp) + dueOff;
        uint256 debt = vault.amountDue(agent);
        vm.prank(owner);
        if (cap == 0 || expiry <= block.timestamp || due < expiry) {
            vm.expectRevert();
            vault.openLine(agent, cap, expiry, due, false);
        } else if (debt > cap) {
            vm.expectRevert(AgentCreditVault.CapBelowDebt.selector);
            vault.openLine(agent, cap, expiry, due, false);
        } else {
            vault.openLine(agent, cap, expiry, due, false);
            assertEq(_line().maxBorrow, cap);
        }
    }
}
