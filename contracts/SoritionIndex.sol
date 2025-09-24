// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SortitionIndex
 * @notice O(log N) weighted index over addresses for random selection by cumulative weight.
 *         - Integrates with BUXToken (controller) via set / setBatch to keep weights in sync with balances.
 *         - Consumed by BUXLotto via totalWeight() and drawByUint(uint256).
 *         - Uses a Fenwick (Binary Indexed) Tree for fast prefix-sum queries and updates.
 *
 * Security model:
 * - Only the designated controller (e.g., BUXToken) may call set/setBatch.
 * - Owner may update the controller address.
 * - No external calls are made in state-changing functions.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ISortitionIndex {
    function totalWeight() external view returns (uint256);
    function drawByUint(uint256 randomValue) external view returns (address);
}

interface ISortitionIndexMutable is ISortitionIndex {
    function set(address account, uint256 weight) external;
    function setBatch(address[] calldata accounts, uint256[] calldata weights) external;
    function weightOf(address account) external view returns (uint256);
    function indexOf(address account) external view returns (uint256);
    function size() external view returns (uint256);
    function accountAt(uint256 index) external view returns (address);
    function controller() external view returns (address);
}

contract SortitionIndex is ISortitionIndexMutable, Ownable {
    // ─────────────────────────────
    // Errors
    // ─────────────────────────────
    error NotController();
    error ZeroAddress();
    error LengthMismatch();
    error EmptyTree();

    // ─────────────────────────────
    // Events
    // ─────────────────────────────
    event ControllerSet(address indexed controller);
    event WeightSet(address indexed account, uint256 prior, uint256 current);
    event BatchSet(uint256 count);

    // ─────────────────────────────
    // Access control
    // ─────────────────────────────
    address private _controller;

    modifier onlyController() {
        if (msg.sender != _controller) revert NotController();
        _;
    }

    function controller() external view returns (address) {
        return _controller;
    }

    /// @notice Owner sets/updates the single controller (expected to be the BUXToken).
    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        _controller = controller_;
        emit ControllerSet(controller_);
    }

    // ─────────────────────────────
    // Storage layout
    // ─────────────────────────────

    // 1-indexed arrays for Fenwick convenience. Slot 0 is unused.
    address[] private _accounts;   // _accounts[i] = address at index i
    uint256[] private _weights;    // _weights[i]  = weight at index i
    uint256[] private _fenwick;    // _fenwick[i]  = fenwick tree partial sum

    // Mapping from account to 1-based index in the arrays (0 => not present)
    mapping(address => uint256) private _indexOf;

    // Cached sum of all weights (kept in sync on updates)
    uint256 private _totalWeight;

    // ─────────────────────────────
    // Constructor
    // ─────────────────────────────
    constructor(address initialOwner) Ownable(initialOwner) {
        // Initialize slot 0 sentinels
        _accounts.push(address(0));
        _weights.push(0);
        _fenwick.push(0);
    }

    // ─────────────────────────────
    // External views (for BUXLotto & tooling)
    // ─────────────────────────────

    /// @inheritdoc ISortitionIndex
    function totalWeight() external view override returns (uint256) {
        return _totalWeight;
    }

    /// @inheritdoc ISortitionIndex
    function drawByUint(uint256 randomValue) external view override returns (address) {
        uint256 tw = _totalWeight;
        if (tw == 0) revert EmptyTree();
        // Map to range [0, tw-1]
        uint256 target = randomValue % tw;
        // Fenwick lower_bound: first index with prefix sum > target
        uint256 idx = _fenwickLowerBound(target);
        return _accounts[idx];
    }

    function weightOf(address account) external view returns (uint256) {
        uint256 idx = _indexOf[account];
        return idx == 0 ? 0 : _weights[idx];
    }

    function indexOf(address account) external view returns (uint256) {
        return _indexOf[account]; // 1-based (0 means "not present")
    }

    function size() external view returns (uint256) {
        return _accounts.length - 1; // exclude sentinel
    }

    function accountAt(uint256 index) external view returns (address) {
        return _accounts[index];
    }

    // ─────────────────────────────
    // Controller API (called by BUXToken)
    // ─────────────────────────────

    /// @notice Add or update a single account's weight.
    function set(address account, uint256 weight) external onlyController {
        _set(account, weight);
    }

    /// @notice Batch add/update. Arrays must match length.
    function setBatch(address[] calldata accounts_, uint256[] calldata weights_) external onlyController {
        uint256 len = accounts_.length;
        if (len != weights_.length) revert LengthMismatch();

        for (uint256 i = 0; i < len; ++i) {
            _set(accounts_[i], weights_[i]);
        }
        emit BatchSet(len);
    }

    // ─────────────────────────────
    // Internal: core mutation
    // ─────────────────────────────

    function _set(address account, uint256 newWeight) internal {
        if (account == address(0)) revert ZeroAddress();

        uint256 idx = _indexOf[account];
        if (idx == 0) {
            // New leaf
            idx = _append(account, newWeight);
        } else {
            // Update existing
            uint256 prior = _weights[idx];
            if (prior == newWeight) return;

            _weights[idx] = newWeight;

            // Update Fenwick with signed delta (new - prior)
            if (newWeight >= prior) {
                _fenwickAdd(idx, newWeight - prior);
                _totalWeight += (newWeight - prior);
            } else {
                uint256 delta = prior - newWeight;
                _fenwickSub(idx, delta);
                _totalWeight -= delta;
            }

            emit WeightSet(account, prior, newWeight);
        }
    }

    function _append(address account, uint256 weight_) internal returns (uint256 idx) {
        // Push to arrays (1-based indexing; slot 0 is sentinel)
        _accounts.push(account);
        _weights.push(weight_);
        _fenwick.push(0); // placeholder; will be updated via _fenwickAdd

        idx = _accounts.length - 1;
        _indexOf[account] = idx;

        if (weight_ != 0) {
            _fenwickAdd(idx, weight_);
            _totalWeight += weight_;
        }

        emit WeightSet(account, 0, weight_);
    }

    // ─────────────────────────────
    // Fenwick tree implementation
    //   - 1-based indexing
    //   - _fenwick[i] stores partial sums
    //   - prefix sum query Σ(1..i) is O(log N)
    //   - update at i by +delta is O(log N)
    //   - lower_bound finds smallest idx with prefix > target in O(log N)
    // ─────────────────────────────

    /// @dev i += i & -i
    function _fenwickAdd(uint256 i, uint256 delta) internal {
        uint256 n = _fenwick.length - 1;
        while (i <= n) {
            _fenwick[i] += delta;
            unchecked { i += (i & (~i + 1)); } // i += LSB(i)
        }
    }

    /// @dev i += i & -i (subtract variant)
    function _fenwickSub(uint256 i, uint256 delta) internal {
        uint256 n = _fenwick.length - 1;
        while (i <= n) {
            _fenwick[i] -= delta;
            unchecked { i += (i & (~i + 1)); }
        }
    }

    /// @dev Returns prefix sum Σ(1..i)
    function _fenwickPrefix(uint256 i) internal view returns (uint256 sum) {
        while (i != 0) {
            sum += _fenwick[i];
            unchecked { i &= (i - 1); } // drop LSB
        }
    }

    /// @dev Find the smallest index `idx` such that prefix(idx) > target, where 0 <= target < totalWeight.
    function _fenwickLowerBound(uint256 target) internal view returns (uint256 idx) {
        uint256 n = _fenwick.length - 1;
        // Compute highest power of two >= n
        uint256 bit = 1;
        while (bit << 1 <= n) {
            unchecked { bit <<= 1; }
        }

        uint256 sum = 0;
        while (bit != 0) {
            uint256 next = idx + bit;
            if (next <= n && _fenwick[next] + sum <= target) {
                sum += _fenwick[next];
                idx = next;
            }
            unchecked { bit >>= 1; }
        }
        // idx is the last index with prefix <= target; answer is the next index (must exist because target < total)
        return idx + 1;
    }
}
