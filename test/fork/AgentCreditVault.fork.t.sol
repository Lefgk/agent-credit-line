// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AgentCreditVault} from "../../src/AgentCreditVault.sol";
import {AgentCreditVaultFactory} from "../../src/AgentCreditVaultFactory.sol";
import {DeployConfig} from "../../script/DeployConfig.sol";
import {FundUsdc} from "../FundUsdc.sol";

/// @dev Runs against a fork of a live chain using the chain's real Circle USDC.
///      Either run `forge test --fork-url <rpc>` (only the matching chain's suite runs), or set
///      MAINNET_FORK_RPC / BASE_FORK_RPC (e.g. a local `anvil --fork-url`). Otherwise skipped.
abstract contract ForkBase is FundUsdc {
    AgentCreditVaultFactory factory;
    AgentCreditVault vault;
    IERC20Metadata usdc;
    address owner = makeAddr("fork-owner");
    address agent = makeAddr("fork-agent");
    address shop = makeAddr("fork-shop");
    address stranger = makeAddr("fork-stranger");
    bool active;

    function _rpcEnv() internal pure virtual returns (string memory);
    function _chainId() internal pure virtual returns (uint256);

    function setUp() public {
        if (block.chainid == _chainId()) {
            // already running on this chain's fork (forge test --fork-url ...)
        } else if (block.chainid == 31337) {
            string memory rpc = vm.envOr(_rpcEnv(), string(""));
            if (bytes(rpc).length == 0) return; // no fork configured -> tests skip
            vm.createSelectFork(rpc);
        } else {
            return; // running on a different chain's fork -> skip
        }
        active = true;
        assertEq(block.chainid, _chainId(), "wrong fork chain");
        usdc = IERC20Metadata(DeployConfig.get(block.chainid).usdc);

        factory = new AgentCreditVaultFactory(address(usdc));
        vm.prank(owner);
        vault = AgentCreditVault(factory.createVault());

        fundUsdc(address(usdc), owner, 10_000e6);
        vm.startPrank(owner);
        IERC20(address(usdc)).approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6);
        vault.openLine(agent, 100e6, uint64(block.timestamp + 7 days), uint64(block.timestamp + 14 days), true);
        vault.setRecipient(agent, shop, true);
        vault.setFeeBps(100); // 1%
        vm.stopPrank();
    }

    modifier onFork() {
        if (!active) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_realUsdcMetadata() public onFork {
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertGt(address(usdc).code.length, 0);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_fork_borrowRepayFeeAndCap() public onFork {
        vm.startPrank(agent);
        vault.borrow(shop, 50e6, "a");
        assertEq(usdc.balanceOf(shop), 50e6);
        assertEq(vault.amountDue(agent), 50.5e6); // 50 + 1%
        vm.expectRevert(abi.encodeWithSelector(AgentCreditVault.ExceedsCredit.selector, 101e6, 100e6));
        vault.borrow(shop, 50e6, "b"); // 50.5 + 50 + 0.5 = 101 > 100
        vault.borrow(shop, 49e6, "c"); // 50.5 + 49.49 = 99.99
        vm.expectRevert(AgentCreditVault.RecipientNotAllowed.selector);
        vault.borrow(stranger, 1, "d");
        vm.stopPrank();

        fundUsdc(address(usdc), agent, 200e6);
        vm.startPrank(agent);
        IERC20(address(usdc)).approve(address(vault), type(uint256).max);
        vault.repay(agent, vault.amountDue(agent));
        vm.stopPrank();
        assertEq(vault.amountDue(agent), 0);
        assertEq(vault.getRecord(agent).totalBorrowed, 99e6);
    }

    function test_fork_defaultRevokePauseWithdraw() public onFork {
        vm.prank(agent);
        vault.borrow(shop, 10e6, "e");

        vm.prank(owner);
        vault.pause();
        vm.prank(agent);
        vm.expectRevert();
        vault.borrow(shop, 1e6, "p");

        fundUsdc(address(usdc), stranger, 20e6);
        vm.startPrank(stranger);
        IERC20(address(usdc)).approve(address(vault), type(uint256).max);
        vault.repay(agent, 10.1e6);
        vm.stopPrank();
        assertEq(vault.amountDue(agent), 0);

        vm.prank(owner);
        vault.unpause();
        vm.prank(agent);
        vault.borrow(shop, 20e6, "again");

        vm.warp(block.timestamp + 15 days);
        vault.markDefault(agent);
        assertTrue(vault.getLine(agent).defaulted);

        vm.prank(owner);
        vault.revokeAgent(agent);
        uint256 before = usdc.balanceOf(owner);
        uint256 leftover = usdc.balanceOf(address(vault));
        vm.prank(owner);
        vault.withdraw(owner, leftover);
        assertEq(usdc.balanceOf(owner), before + leftover);
    }

    function testFuzz_fork_creditCapHolds(uint256 a1, uint256 a2, uint256 a3) public onFork {
        uint256[3] memory amts = [bound(a1, 1, 80e6), bound(a2, 1, 80e6), bound(a3, 1, 80e6)];
        uint256 debt;
        for (uint256 i; i < 3; i++) {
            vm.prank(agent);
            try vault.borrow(shop, amts[i], bytes32(i)) {
                debt += amts[i] + (amts[i] * 100) / 10_000;
            } catch {}
        }
        assertLe(debt, 100e6);
        assertEq(vault.amountDue(agent), debt);
    }
}

contract EthereumForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "MAINNET_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 1;
    }
}

contract BaseForkTest is ForkBase {
    function _rpcEnv() internal pure override returns (string memory) {
        return "BASE_FORK_RPC";
    }

    function _chainId() internal pure override returns (uint256) {
        return 8453;
    }
}
