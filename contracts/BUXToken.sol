// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title BUXToken
 * @notice ERC20 token used for BUX Lotto weighted drawings.
 *         Eligibility defaults: EOAs included if balance ≥ minEligibleBalance.
 *         Contracts are excluded by default unless explicitly allowlisted via setContractEligible.
 *         Protocol addresses (Safe, Lotto, Hook, Splitter) should be marked pause-exempt and no-contagion.
 *
 *         The token integrates with a SortitionIndex (sum/Fenwick tree) to maintain per-account weights:
 *         weight(account) = isEligible(account) ? balanceOf(account) : 0.
 *
 *         The SortitionIndex address is set once via initSortitionIndex(...) and then frozen permanently.
 *         Transfers/mint/burn push fresh weights to the index (post-balance update).
 *
 *         Pausing: When paused, transfers are blocked unless one side is pause-exempt or msg.sender is the owner.
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface ISortitionIndexMutable {
    function set(address account, uint256 weight) external;
    function setBatch(address[] calldata accounts, uint256[] calldata weights) external;
    function totalWeight() external view returns (uint256);
    function weightOf(address account) external view returns (uint256);
}

contract BUXToken is ERC20, Ownable, Pausable {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error AlreadyInitialized();
    error NotInitialized();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event MinEligibleBalanceUpdated(uint256 oldValue, uint256 newValue);
    event ContractEligibilitySet(address indexed account, bool isEligible);
    event PauseExemptSet(address indexed account, bool isExempt);
    event NoContagionSet(address indexed account, bool isNoContagion);
    event SortitionIndexInitialized(address indexed index);

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    // None

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    // Minimum token balance (in wei of BUX) required for eligibility.
    uint256 private _minEligibleBalance;

    // Contracts are ineligible by default. This explicit allowlist lets specific contracts be eligible.
    mapping(address => bool) public contractEligible;

    // When paused, transfers are blocked unless from or to is pause-exempt (or owner calls).
    mapping(address => bool) public pauseExempt;

    // Optional tagging for protocol addresses to opt-out of any future contagion logic.
    // (No contagion propagation is performed in this contract, but we expose the flag for ecosystem tooling.)
    mapping(address => bool) public noContagion;

    // Sortition index (frozen after initialization).
    ISortitionIndexMutable private _index;
    bool public indexFrozen;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param name_                 ERC20 name
     * @param symbol_               ERC20 symbol
     * @param initialOwner          owner address (Gnosis Safe recommended)
     * @param initialRecipient      address to receive the initial supply (can be the Safe)
     * @param initialSupply         amount minted to initialRecipient (in wei of BUX)
     * @param minEligibleBalance_   minimum balance for eligibility (in wei of BUX)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address initialRecipient,
        uint256 initialSupply,
        uint256 minEligibleBalance_
    ) ERC20(name_, symbol_) Ownable(initialOwner) {
        if (initialRecipient == address(0)) revert ZeroAddress();
        _minEligibleBalance = minEligibleBalance_;
        _mint(initialRecipient, initialSupply);
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL: ADMIN (OWNER)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause all non-exempt transfers.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause transfers.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set/replace the minimum eligible balance.
    function setMinEligibleBalance(uint256 newMin) external onlyOwner {
        uint256 old = _minEligibleBalance;
        _minEligibleBalance = newMin;
        emit MinEligibleBalanceUpdated(old, newMin);
        // NOTE: This does not auto-resync all holders (gas prohibitive).
        // Use resyncWeights(address[]) for targeted updates when thresholds change.
    }

    /// @notice Mark/unmark a contract as eligible (EOAs are eligible by default if threshold satisfied).
    function setContractEligible(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        contractEligible[account] = allowed;
        emit ContractEligibilitySet(account, allowed);
        _pushWeight(account);
    }

    /// @notice Mark/unmark an address as pause-exempt (can transfer while paused).
    function setPauseExempt(address account, bool isExempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        pauseExempt[account] = isExempt;
        emit PauseExemptSet(account, isExempt);
    }

    /// @notice Mark/unmark an address as no-contagion (reserved for ecosystem tools; no effect here).
    function setNoContagion(address account, bool isNoContagion) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        noContagion[account] = isNoContagion;
        emit NoContagionSet(account, isNoContagion);
    }

    /**
     * @notice One-time initialization of the SortitionIndex. Irreversible.
     *         Seeds the owner's initial weight (others update on their next balance change or via resync).
     */
    function initSortitionIndex(address index_) external onlyOwner {
        if (indexFrozen) revert AlreadyInitialized();
        if (index_ == address(0)) revert ZeroAddress();

        _index = ISortitionIndexMutable(index_);
        indexFrozen = true;
        emit SortitionIndexInitialized(index_);

        // (Optional but recommended) ensure this token is the controller
        // so future set()/setBatch() calls from this contract succeed.
        // If your SortitionIndex doesn’t expose controller(), delete this block.
        try _index.controller() returns (address ctl) {
            if (ctl != address(this)) {
                // Not fatal: we continue so deploy scripts can setController later.
                // If you prefer to hard-fail, replace with a revert.
            }
        } catch {
            // Older interfaces may not have controller(); ignore.
        }

        // Seed the initial owner’s weight (common case: mint already happened).
        address;
        uint256;
        accounts[0] = owner();
        weights[0]  = isEligible(accounts[0]) ? balanceOf(accounts[0]) : 0;

        // Prefer batch to align with index usage; fallback to single on failure.
        try _index.setBatch(accounts, weights) {
            // ok
        } catch {
            try _index.set(accounts[0], weights[0]) {
                // ok
            } catch {
                // Not fatal: if index rejects now (e.g., controller not set yet),
                // subsequent transfers will keep pushing live weights via _update().
            }
        }
    }


    /**
     * @notice Owner-triggered targeted resync for specific accounts (e.g., after threshold change).
     * @dev    Reverts if the index is not initialized yet.
     */
    function resyncWeights(address[] calldata accounts) external onlyOwner {
        if (!indexFrozen) revert NotInitialized();
        uint256 len = accounts.length;
        if (len == 0) return;

        // Best effort batch: try setBatch first; if it fails (e.g., index disallows),
        // fall back to individual sets to salvage partial progress.
        address[] memory addrs = new address[](len);
        uint256[] memory weights = new uint256[](len);
        unchecked {
            for (uint256 i = 0; i < len; i++) {
                address a = accounts[i];
                addrs[i] = a;
                weights[i] = isEligible(a) ? balanceOf(a) : 0;
            }
        }

        try _index.setBatch(addrs, weights) {
            // ok
        } catch {
            unchecked {
                for (uint256 i = 0; i < len; i++) {
                    // swallow individual failures to avoid blocking the entire call
                    try _index.set(addrs[i], weights[i]) {} catch {}
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              PUBLIC VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the minimum balance required for eligibility.
    function minEligibleBalance() external view returns (uint256) {
        return _minEligibleBalance;
    }

    /// @notice Returns the SortitionIndex address (zero if not initialized).
    function sortitionIndex() external view returns (address) {
        return address(_index);
    }

    /// @notice Whether the account is currently eligible for lottery weighting.
    function isEligible(address account) public view returns (bool) {
        if (account == address(0)) return false;
        uint256 bal = balanceOf(account);
        if (bal < _minEligibleBalance) return false;

        // Contracts default to ineligible unless allowlisted.
        if (_hasCode(account) && !contractEligible[account]) {
            return false;
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNALS: TRANSFER HOOKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev OZ v5 ERC20 transfer/mint/burn funnel through _update.
     *      We enforce pause policy and then push fresh weights to the index for changed accounts.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        // Pause policy: allow if not paused OR if one side is exempt OR if owner is executing.
        if (paused()) {
            bool allowed =
                (msg.sender == owner()) ||
                (from != address(0) && pauseExempt[from]) ||
                (to != address(0) && pauseExempt[to]) ||
                // Allow mint/burn from owner while paused (constructor mint already happened before pause can be set).
                (from == address(0) && msg.sender == owner()) ||
                (to == address(0) && msg.sender == owner());
            require(allowed, "BUXToken: paused");
        }

        // Perform balance update first.
        super._update(from, to, value);

        // Push fresh weights post-update.
        if (from != address(0)) _pushWeight(from);
        if (to != address(0)) _pushWeight(to);
    }

    /// @dev Best-effort weight push; no-op if index not initialized.
    function _pushWeight(address account) internal {
        if (!indexFrozen) return;

        uint256 w = isEligible(account) ? balanceOf(account) : 0;
        // Avoid reverting the transfer path if the index rejects (best effort).
        try _index.set(account, w) {
            // ok
        } catch {
            // swallow
        }
    }

    /// @dev Detects whether an address has code (contract).
    function _hasCode(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
