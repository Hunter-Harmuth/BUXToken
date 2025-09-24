// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ─────────────────────────────────────────────────────────────────────────────
// External dependencies (OpenZeppelin v5)
// ─────────────────────────────────────────────────────────────────────────────
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DevFeeSplitter
/// @notice Receives the dev-fee ETH (e.g., from the v4 hook) and accrues per-recipient balances.
/// @dev No external calls in receive/fund path; payouts are pull-based for safety. All math uses BPS (1e4).
contract DevFeeSplitter is Ownable, Pausable, ReentrancyGuard {
    // ─────────────────────────────
    // Constants / Errors
    // ─────────────────────────────
    uint16 public constant BPS_DENOMINATOR = 10_000;

    error ZeroAddress();
    error LengthMismatch();
    error SharesNot100();
    error NothingToClaim();
    error IndexOutOfBounds();
    error AlreadyFrozen();

    // ─────────────────────────────
    // Recipients & Shares
    // ─────────────────────────────
    address[] private _recipients;     // dev1, dev2, dev3, dev4, group ...
    uint16[]  private _sharesBps;      // must sum to 10_000 (i.e., 100% of the *dev portion*)
    uint8 public remainderSinkIndex;   // index to receive rounding remainders
    bool public frozen;                // once frozen, recipient config cannot change

    // ─────────────────────────────
    // Accounting
    // ─────────────────────────────
    mapping(address => uint256) public claimableEth;
    uint256 public totalClaimable;

    // ─────────────────────────────
    // Events
    // ─────────────────────────────
    event FundReceived(address indexed from, uint256 amount);
    event Accrued(address indexed recipient, uint256 amount);
    event Claimed(address indexed recipient, address indexed to, uint256 amount);
    event RecipientsUpdated(address[] recipients, uint16[] sharesBps, uint8 remainderSinkIndex);
    event Frozen();
    event RemainderSinkIndexSet(uint8 index);
    event EmergencyWithdrawn(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event Paused();
    event Unpaused();

    // ─────────────────────────────
    // Constructor
    // ─────────────────────────────
    /// @param initialOwner Owner address (e.g., your SAFE)
    /// @param recipients   Recipient addresses (e.g., DEV_WALLET_1..4, GROUP_WALLET)
    /// @param sharesBps    BPS shares within the *dev* portion; must sum to 10_000 (100%)
    /// @param remainderIdx Index in `recipients` to receive rounding dust
    constructor(
        address initialOwner,
        address[] memory recipients,
        uint16[]  memory sharesBps,
        uint8 remainderIdx
    ) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        _setRecipients(recipients, sharesBps, remainderIdx);
    }

    // ─────────────────────────────
    // Funding
    // ─────────────────────────────
    /// @notice Accept ETH and accrue balances; anyone can fund (hook, EOAs, etc.).
    receive() external payable {
        _accrue(msg.value);
        emit FundReceived(msg.sender, msg.value);
    }

    /// @notice Convenience method identical to receive() but with explicit selector.
    function fund() external payable {
        _accrue(msg.value);
        emit FundReceived(msg.sender, msg.value);
    }

    // ─────────────────────────────
    // Claims (pull-based withdrawals)
    // ─────────────────────────────
    /// @notice Claim your entire accrued balance to your own address.
    function claim() external nonReentrant whenNotPaused {
        _claimTo(payable(msg.sender), claimableEth[msg.sender]);
    }

    /// @notice Claim up to `amount` to your own address.
    function claim(uint256 amount) external nonReentrant whenNotPaused {
        _claimTo(payable(msg.sender), amount);
    }

    /// @notice Claim your entire accrued balance to a different address.
    function claimTo(address payable to) external nonReentrant whenNotPaused {
        _claimTo(to, claimableEth[msg.sender]);
    }

    /// @notice Batch payouts for multiple recipients (anyone can call).
    function payoutMany(address[] calldata recipients) external nonReentrant whenNotPaused {
        uint256 len = recipients.length;
        for (uint256 i = 0; i < len; ++i) {
            address r = recipients[i];
            uint256 amt = claimableEth[r];
            if (amt == 0) continue;
            _claimSpecific(payable(r), amt);
        }
    }

    // ─────────────────────────────
    // Admin: recipients & shares
    // ─────────────────────────────
    function setRecipients(
        address[] calldata recipients,
        uint16[]  calldata sharesBps,
        uint8 remainderIdx
    ) external onlyOwner {
        if (frozen) revert AlreadyFrozen();
        _setRecipients(recipients, sharesBps, remainderIdx);
    }

    /// @notice Freeze the recipient configuration permanently.
    function freeze() external onlyOwner {
        if (frozen) revert AlreadyFrozen();
        frozen = true;
        emit Frozen();
    }

    /// @notice Change which index gets integer-division remainder on accruals.
    function setRemainderSinkIndex(uint8 index) external onlyOwner {
        if (index >= _recipients.length) revert IndexOutOfBounds();
        remainderSinkIndex = index;
        emit RemainderSinkIndexSet(index);
    }

    // ─────────────────────────────
    // Admin: pause & rescue
    // ─────────────────────────────
    function pause() external onlyOwner {
        _pause();
        emit Paused();
    }

    function unpause() external onlyOwner {
        _unpause();
        emit Unpaused();
    }

    /// @notice Emergency withdraw unallocated ETH (should normally be zero; all deposits are allocated).
    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
        emit EmergencyWithdrawn(to, amount);
    }

    /// @notice Rescue unrelated ERC20 tokens accidentally sent to this contract (not used by protocol).
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        bool ok = IERC20(token).transfer(to, amount);
        require(ok, "ERC20 rescue failed");
        emit ERC20Rescued(token, to, amount);
    }

    // ─────────────────────────────
    // Views
    // ─────────────────────────────
    function recipients() external view returns (address[] memory) {
        return _recipients;
    }

    function sharesBps() external view returns (uint16[] memory) {
        return _sharesBps;
    }

    function recipientsCount() external view returns (uint256) {
        return _recipients.length;
    }

    function pending(address account) external view returns (uint256) {
        return claimableEth[account];
    }

    // ─────────────────────────────
    // Internal logic
    // ─────────────────────────────
    function _setRecipients(
        address[] memory recipients_,
        uint16[]  memory sharesBps_,
        uint8 remainderIdx
    ) internal {
        uint256 len = recipients_.length;
        if (len == 0) revert LengthMismatch();
        if (len != sharesBps_.length) revert LengthMismatch();
        if (remainderIdx >= len) revert IndexOutOfBounds();

        uint256 sum;
        for (uint256 i = 0; i < len; ++i) {
            if (recipients_[i] == address(0)) revert ZeroAddress();
            sum += sharesBps_[i];
        }
        if (sum != BPS_DENOMINATOR) revert SharesNot100();

        _recipients = recipients_;
        _sharesBps  = sharesBps_;
        remainderSinkIndex = remainderIdx;

        emit RecipientsUpdated(recipients_, sharesBps_, remainderIdx);
    }

    function _accrue(uint256 amount) internal {
        if (amount == 0) return;

        uint256 len = _recipients.length;
        uint256 distributed;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                uint256 part = (amount * _sharesBps[i]) / BPS_DENOMINATOR;
                if (part == 0) continue;
                claimableEth[_recipients[i]] += part;
                distributed += part;
                emit Accrued(_recipients[i], part);
            }
        }

        // Allocate integer-division dust to the designated sink
        uint256 dust = amount - distributed;
        if (dust > 0) {
            address sink = _recipients[remainderSinkIndex];
            claimableEth[sink] += dust;
            emit Accrued(sink, dust);
        }

        totalClaimable += amount;
    }

    function _claimTo(address payable to, uint256 amount) internal {
        if (amount == 0) revert NothingToClaim();
        if (amount > claimableEth[msg.sender]) amount = claimableEth[msg.sender];
        _claimSpecific(to, amount);
    }

    function _claimSpecific(address payable to, uint256 amount) internal {
        // Effects
        address recipient = msg.sender == address(this) ? to : msg.sender;
        // When called via payoutMany, msg.sender is the caller; we want to pay `to` and
        // reduce the claimable of `to`, not msg.sender. So detect and handle explicitly.
        if (to != msg.sender) {
            // payoutMany path
            claimableEth[to] -= amount;
            totalClaimable -= amount;
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "claim transfer failed");
            emit Claimed(to, to, amount);
            return;
        }

        // Standard claim path (msg.sender claims for themselves or claimTo)
        claimableEth[recipient] -= amount;
        totalClaimable -= amount;

        // Interaction
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "claim transfer failed");
        emit Claimed(recipient, to, amount);
    }
}
