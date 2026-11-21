// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title AgentCreditVault
/// @notice Owner-funded USDC credit lines for AI agent addresses. Each line has a max borrow,
///         a borrow expiry, a repay-by due date, an optional destination allowlist, and a public
///         repayment / default record. v1 is fully owner-collateralized: no pooled lenders, no
///         interest. The owner may set an optional flat fee in basis points charged on each borrow
///         and added to the agent's debt (repaid first). Anyone may repay. The owner (or an
///         optional guardian) can pause the vault or revoke a line instantly.
/// @dev    PROTOTYPE - NOT AUDITED. USDC only. Agents cannot make arbitrary calls.
contract AgentCreditVault is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct Line {
        bool active; // false = revoked / never opened
        bool allowlistEnabled; // if true, borrow `to` must be allowlisted
        bool defaulted; // sticky until owner clears after full repayment
        uint64 expiry; // last timestamp the agent may borrow (exclusive)
        uint64 dueDate; // repay-by deadline; after this, anyone may mark default
        uint32 epoch; // bumped on revoke so the old allowlist dies
        uint128 maxBorrow; // cap on outstanding debt (principal + unpaid fee)
        uint128 principal; // outstanding principal
        uint128 feeOwed; // outstanding flat fees
    }

    struct Record {
        uint64 lastDefaultAt; // 0 if never defaulted
        uint32 borrowCount;
        uint32 repayCount;
        uint32 defaultCount;
        uint128 totalBorrowed; // lifetime principal borrowed
        uint128 totalRepaid; // lifetime USDC repaid
    }

    IERC20 public immutable usdc;

    /// @notice Optional address that can pause and revoke, but never open lines or withdraw.
    address public guardian;

    /// @notice Flat fee in bps charged on each borrow and added to debt. 0 = no fee.
    uint16 public feeBps;

    /// @notice Sum of outstanding principal across all agents.
    uint256 public totalPrincipal;

    /// @notice Sum of unpaid fees across all agents.
    uint256 public totalFeeOwed;

    mapping(address agent => Line) public lines;
    mapping(address agent => Record) public records;
    /// @dev key = keccak256(agent, epoch, recipient)
    mapping(bytes32 key => bool) internal _recipientAllowed;

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event GuardianSet(address indexed guardian);
    event FeeBpsSet(uint16 feeBps);
    event LineOpened(
        address indexed agent,
        uint128 maxBorrow,
        uint64 expiry,
        uint64 dueDate,
        bool allowlistEnabled,
        uint32 epoch
    );
    event AgentRevoked(address indexed agent, address indexed by, uint32 newEpoch);
    event RecipientSet(address indexed agent, address indexed recipient, bool allowed);
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
    event DefaultCleared(address indexed agent, address indexed by);

    error NotAgent();
    error AgentExpired();
    error LineDue();
    error LineDefaulted();
    error RecipientNotAllowed();
    error ExceedsCredit(uint256 wouldDebt, uint256 cap);
    error InsufficientLiquidity();
    error InvalidLine();
    error InvalidExpiry();
    error InvalidFee();
    error ZeroAddress();
    error ZeroAmount();
    error NoDebt();
    error NotDue();
    error AlreadyDefaulted();
    error NotDefaulted();
    error DebtOutstanding();
    error CapBelowDebt();
    error NotOwnerOrGuardian();

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        _;
    }

    constructor(address initialOwner, address usdc_) Ownable(initialOwner) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    // ------------------------------------------------------------------ funding

    /// @notice Pull USDC into the vault (needs prior approve). Records the amount actually received.
    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = usdc.balanceOf(address(this));
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, usdc.balanceOf(address(this)) - before);
    }

    /// @notice Owner withdraws unused USDC (vault balance). Works even while paused so funds are never stuck.
    function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        usdc.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    // ------------------------------------------------------------------ admin

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Set the flat borrow fee in basis points (0..1000). Does not change existing debt.
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee();
        feeBps = newFeeBps;
        emit FeeBpsSet(newFeeBps);
    }

    /// @notice Open or update a credit line. `dueDate` must be at or after `expiry`.
    ///         `maxBorrow` cannot be set below current outstanding debt. If debt is zero,
    ///         a default flag is cleared (owner reinstatement).
    function openLine(address agent, uint128 maxBorrow, uint64 expiry, uint64 dueDate, bool allowlistEnabled)
        external
        onlyOwner
    {
        if (agent == address(0)) revert ZeroAddress();
        if (maxBorrow == 0) revert InvalidLine();
        if (expiry <= block.timestamp || dueDate < expiry) revert InvalidExpiry();

        Line storage line = lines[agent];
        uint256 debt = uint256(line.principal) + line.feeOwed;
        if (debt > maxBorrow) revert CapBelowDebt();

        line.active = true;
        line.maxBorrow = maxBorrow;
        line.expiry = expiry;
        line.dueDate = dueDate;
        line.allowlistEnabled = allowlistEnabled;
        if (debt == 0 && line.defaulted) {
            line.defaulted = false;
            emit DefaultCleared(agent, msg.sender);
        }
        emit LineOpened(agent, maxBorrow, expiry, dueDate, allowlistEnabled, line.epoch);
    }

    function setRecipient(address agent, address recipient, bool allowed) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        _recipientAllowed[_key(agent, lines[agent].epoch, recipient)] = allowed;
        emit RecipientSet(agent, recipient, allowed);
    }

    /// @notice Kill switch for one agent: deactivates the line and wipes its allowlist.
    ///         Outstanding debt and the public record remain.
    function revokeAgent(address agent) external onlyOwnerOrGuardian {
        _revoke(agent);
    }

    /// @notice An agent can give up its own borrowing rights, e.g. if its key leaks. Debt remains.
    function renounceAgent() external {
        if (!lines[msg.sender].active) revert NotAgent();
        _revoke(msg.sender);
    }

    function pause() external onlyOwnerOrGuardian {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Anyone may mark a line defaulted after `dueDate` if debt remains. Blocks new borrows
    ///         until the owner clears the flag after a full repayment.
    function markDefault(address agent) external {
        Line storage line = lines[agent];
        uint256 debt = uint256(line.principal) + line.feeOwed;
        if (debt == 0) revert NoDebt();
        if (block.timestamp <= line.dueDate) revert NotDue();
        if (line.defaulted) revert AlreadyDefaulted();
        line.defaulted = true;
        Record storage rec = records[agent];
        unchecked {
            rec.defaultCount += 1;
        }
        rec.lastDefaultAt = uint64(block.timestamp);
        emit Defaulted(agent, debt, msg.sender);
    }

    /// @notice Owner may clear a default only after the line is fully repaid, so the agent can borrow again.
    function clearDefault(address agent) external onlyOwner {
        Line storage line = lines[agent];
        if (!line.defaulted) revert NotDefaulted();
        if (uint256(line.principal) + line.feeOwed != 0) revert DebtOutstanding();
        line.defaulted = false;
        emit DefaultCleared(agent, msg.sender);
    }

    // ------------------------------------------------------------------ borrow / repay

    /// @notice Agent borrows `amount` of USDC, sent to `to`. A flat fee (if set) is added to debt.
    function borrow(address to, uint256 amount, bytes32 memo) external whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Line storage line = lines[msg.sender];
        if (!line.active) revert NotAgent();
        if (line.defaulted) revert LineDefaulted();
        if (block.timestamp >= line.expiry) revert AgentExpired();
        if (block.timestamp >= line.dueDate) revert LineDue();
        if (line.allowlistEnabled && !_recipientAllowed[_key(msg.sender, line.epoch, to)]) {
            revert RecipientNotAllowed();
        }

        uint256 fee = _feeOn(amount);
        uint256 newDebt = uint256(line.principal) + line.feeOwed + amount + fee;
        if (newDebt > line.maxBorrow) revert ExceedsCredit(newDebt, line.maxBorrow);
        if (amount > usdc.balanceOf(address(this))) revert InsufficientLiquidity();
        if (amount > type(uint128).max - line.principal) revert ExceedsCredit(newDebt, line.maxBorrow);
        if (fee > type(uint128).max - line.feeOwed) revert ExceedsCredit(newDebt, line.maxBorrow);

        line.principal = uint128(uint256(line.principal) + amount);
        line.feeOwed = uint128(uint256(line.feeOwed) + fee);
        Record storage rec = records[msg.sender];
        rec.totalBorrowed = uint128(uint256(rec.totalBorrowed) + amount);
        unchecked {
            rec.borrowCount += 1;
        }
        totalPrincipal += amount;
        totalFeeOwed += fee;

        emit Borrowed(msg.sender, to, amount, fee, newDebt, memo);
        usdc.safeTransfer(to, amount);
    }

    /// @notice Anyone may repay an agent's debt. Overpayments are capped to the outstanding amount.
    ///         Allowed while paused, after revoke, and after default.
    function repay(address agent, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Line storage line = lines[agent];
        uint256 debt = uint256(line.principal) + line.feeOwed;
        if (debt == 0) revert NoDebt();
        uint256 pay = amount > debt ? debt : amount;

        usdc.safeTransferFrom(msg.sender, address(this), pay);

        uint256 feePay = pay <= line.feeOwed ? pay : uint256(line.feeOwed);
        uint256 principalPay = pay - feePay;
        line.feeOwed = uint128(uint256(line.feeOwed) - feePay);
        line.principal = uint128(uint256(line.principal) - principalPay);
        totalFeeOwed -= feePay;
        totalPrincipal -= principalPay;
        Record storage rec = records[agent];
        rec.totalRepaid = uint128(uint256(rec.totalRepaid) + pay);
        unchecked {
            rec.repayCount += 1;
        }

        emit Repaid(agent, msg.sender, pay, uint256(line.principal) + line.feeOwed);
    }

    // ------------------------------------------------------------------ views (incl. ERC-8460-shaped names)

    function getLine(address agent) external view returns (Line memory) {
        return lines[agent];
    }

    function getRecord(address agent) external view returns (Record memory) {
        return records[agent];
    }

    function isRecipientAllowed(address agent, address recipient) external view returns (bool) {
        Line memory line = lines[agent];
        if (!line.allowlistEnabled) return recipient != address(0);
        return _recipientAllowed[_key(agent, line.epoch, recipient)];
    }

    /// @notice Outstanding debt (principal + unpaid fee). ERC-8460-shaped `amountDue`.
    function amountDue(address agent) public view returns (uint256) {
        Line memory line = lines[agent];
        return uint256(line.principal) + line.feeOwed;
    }

    /// @notice Remaining credit, capped by vault liquidity, or 0 if the agent cannot borrow now.
    function availableCredit(address agent) public view returns (uint256) {
        Line memory line = lines[agent];
        if (
            !line.active || line.defaulted || paused() || block.timestamp >= line.expiry
                || block.timestamp >= line.dueDate
        ) return 0;
        uint256 debt = uint256(line.principal) + line.feeOwed;
        if (debt >= line.maxBorrow) return 0;
        uint256 room = uint256(line.maxBorrow) - debt;
        // A fee is charged on the principal received, so the largest principal P satisfies
        // P + fee(P) <= room. With fee = P * bps / 10000: P <= room * 10000 / (10000 + bps).
        if (feeBps > 0) {
            room = (room * BPS_DENOMINATOR) / (uint256(BPS_DENOMINATOR) + feeBps);
        }
        uint256 bal = usdc.balanceOf(address(this));
        return room < bal ? room : bal;
    }

    /// @notice Quote the fee and resulting debt for a borrow of `amount` (does not check the cap).
    function quote(uint256 amount) public view returns (uint256 fee, uint256 debtDelta) {
        fee = _feeOn(amount);
        debtDelta = amount + fee;
    }

    function liquidity() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ------------------------------------------------------------------ internal

    function _feeOn(uint256 amount) internal view returns (uint256) {
        if (feeBps == 0) return 0;
        return (amount * feeBps) / BPS_DENOMINATOR;
    }

    function _key(address agent, uint32 epoch, address x) internal pure returns (bytes32) {
        return keccak256(abi.encode(agent, epoch, x));
    }

    function _revoke(address agent) internal {
        Line storage line = lines[agent];
        line.active = false;
        unchecked {
            line.epoch += 1;
        }
        emit AgentRevoked(agent, msg.sender, line.epoch);
    }
}
