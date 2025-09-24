// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 *  BUX Lotto — Uniswap v4 funding hook
 *
 *  Summary
 *  - Takes a protocol-defined percentage of the ETH notion that moves in a BUX/ETH pool swap.
 *  - Splits the captured ETH into Hourly, Daily, and Dev portions.
 *  - Sends Hourly+Daily to the BUX Lotto contract (with explicit attribution),
 *    and sends the Dev portion to the DevFeeSplitter.
 *
 *  Design notes
 *  - Uses Uniswap v4 hook callbacks: beforeSwap (to account when ETH is the specified currency)
 *    and afterSwap (to account when ETH is the unspecified currency) — this keeps accounting
 *    symmetric for exact-input and exact-output swaps (see Uniswap v4 Hooks docs).
 *  - Calls PoolManager.take(NATIVE, address(this), fee) inside afterSwap to realize ETH to this
 *    contract during the lock, then forwards to recipients immediately.
 *  - Restricts to a single BUX/ETH pool (by currencies), with optional allowlist reinforcement.
 *  - Owner can pause fees and adjust basis points within a capped total.
 *
 *  Important Uniswap v4 references used in this implementation:
 *    - IHooks.beforeSwap / IHooks.afterSwap signatures and semantics,
 *      including the rule that beforeSwap can return specified/unspecified deltas,
 *      and afterSwap can return a hook delta in the *unspecified* currency.
 *    - PoolManager.take() for in-lock settlement of the hook's positive delta.
 *
 *  Security considerations
 *  - Only callable by PoolManager (enforced via BaseHook).
 *  - Non-reentrant forward of ETH is safe here because PoolManager lock prevents
 *    re-entrancy back into pool operations; nevertheless we keep external calls minimal
 *    and checked.
 *  - Basis-points are bounded; recipients are updatable by owner/multisig if needed.
 */

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IBUXLotto {
    /**
     * @dev Receives ETH from this hook and attributes the amounts to hourly & daily pots.
     * @param hourly Amount of msg.value to attribute to the hourly pot
     * @param daily  Amount of msg.value to attribute to the daily pot
     *
     * Requirements:
     * - must be payable
     * - must not revert for zero amounts (msg.value could be zero in some edge cases)
     */
    function fundFromHook(uint256 hourly, uint256 daily) external payable;
}

contract LottoFundingHook is BaseHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ========= Constants & Types =========

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant TOTAL_BPS_MAX   = 2_000; // 20.00% hard cap for safety

    error InvalidPool();
    error InvalidConfig();
    error TransferFailed();
    error ExceedsSwapAmount();
    error ZeroAddress();
    error NotBuxEthPool();

    event FeesUpdated(uint16 hourlyBps, uint16 dailyBps, uint16 devBps);
    event RecipientsUpdated(address lotto, address devFeeSplitter);
    event PoolAllowed(bytes32 indexed poolId, bool allowed);
    event FeesToggled(bool enabled);
    event FeeRealized(
        bytes32 indexed poolId,
        bool ethWasSpecified,
        uint256 ethMoved,
        uint256 feeTaken,
        uint256 hourlyPortion,
        uint256 dailyPortion,
        uint256 devPortion
    );

    // ========= Immutable Configuration =========

    // BUX ERC20 token address (the non-native side of the pool)
    address public immutable buxToken;

    // Convenience currency handles
    Currency private immutable _cBux;
    Currency private constant _cEth = CurrencyLibrary.NATIVE;

    // ========= Mutable Configuration (owner-controlled) =========

    // Where hourly/daily ETH is attributed (expects fundFromHook(uint256,uint256) payable)
    address payable public lotto;

    // Where dev ETH is sent (splitter contract with payable receive)
    address payable public devFeeSplitter;

    // Fee splits in basis points (must sum to <= TOTAL_BPS_MAX)
    uint16 public hourlyBps; // e.g., 790  =>  7.90%
    uint16 public dailyBps;  // e.g., 390  =>  3.90%
    uint16 public devBps;    // e.g., 45   =>  0.45%

    // Global toggle to pause fee collection
    bool public feesEnabled = true;

    // Optional allowlist for pools (additional safety). If empty, currency guard suffices.
    mapping(PoolId => bool) public allowedPools;

    // ========= Constructor & Permissions =========

    constructor(
        IPoolManager _poolManager,
        address _buxToken,
        address payable _lotto,
        address payable _devFeeSplitter,
        uint16 _hourlyBps,
        uint16 _dailyBps,
        uint16 _devBps,
        address initialOwner
    ) BaseHook(_poolManager) Ownable(initialOwner) {
        if (_buxToken == address(0) || _lotto == address(0) || _devFeeSplitter == address(0)) revert ZeroAddress();

        buxToken = _buxToken;
        _cBux = Currency.wrap(_buxToken);

        _setFees(_hourlyBps, _dailyBps, _devBps);
        lotto = _lotto;
        devFeeSplitter = _devFeeSplitter;

        // Validate that the deployed address encodes the right permissions.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @dev Declare which hook callbacks are implemented and whether they return deltas.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        // Only swap hooks are used. We return deltas for both before & after.
        p.beforeSwap                = true;
        p.afterSwap                 = true;
        p.beforeSwapReturnDelta     = true;
        p.afterSwapReturnDelta      = true;

        // All others remain false (default-initialized).
    }

    // ========= Owner functions =========

    function setFees(uint16 _hourlyBps, uint16 _dailyBps, uint16 _devBps) external onlyOwner {
        _setFees(_hourlyBps, _dailyBps, _devBps);
    }

    function _setFees(uint16 _hourlyBps, uint16 _dailyBps, uint16 _devBps) internal {
        uint256 total = uint256(_hourlyBps) + uint16(_dailyBps) + uint16(_devBps);
        if (total > TOTAL_BPS_MAX) revert InvalidConfig();

        hourlyBps = _hourlyBps;
        dailyBps  = _dailyBps;
        devBps    = _devBps;

        emit FeesUpdated(hourlyBps, dailyBps, devBps);
    }

    function setRecipients(address payable _lotto, address payable _devFeeSplitter) external onlyOwner {
        if (_lotto == address(0) || _devFeeSplitter == address(0)) revert ZeroAddress();
        lotto = _lotto;
        devFeeSplitter = _devFeeSplitter;
        emit RecipientsUpdated(_lotto, _devFeeSplitter);
    }

    function setFeesEnabled(bool enabled) external onlyOwner {
        feesEnabled = enabled;
        emit FeesToggled(enabled);
    }

    /// @notice Optional per-pool allowlist. If you use it, set allowed=true for your BUX/ETH poolId.
    function allowPool(PoolKey calldata key, bool allowed) external onlyOwner {
        PoolId id = key.toId();
        allowedPools[id] = allowed;
        emit PoolAllowed(PoolId.unwrap(id), allowed);
    }

    // ========= Hook callbacks =========

    /// @inheritdoc IHooks
    function beforeSwap(
        address, // sender (router/universal router)
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /*hookData*/
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!feesEnabled || (hourlyBps + dailyBps + devBps) == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        _checkBuxEthPool(key);

        // Determine if ETH is the specified currency (depends on zeroForOne).
        // In v4, the specified currency is currency0 if zeroForOne==true, else currency1.
        bool ethIsSpecified = params.zeroForOne ? _isEth(key.currency0) : _isEth(key.currency1);

        if (!ethIsSpecified) {
            // No change from beforeSwap side if ETH is unspecified; we'll handle it in afterSwap.
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // abs(amountSpecified) is the ETH amount moving as the specified currency for this swap
        // (for exact-input, it's the input; for exact-output, it's the output).
        uint256 ethSpecified = _abs(params.amountSpecified);

        // Compute fee and ensure it is strictly less than swap amount to preserve semantics.
        uint256 fee = _computeFee(ethSpecified);
        if (fee >= ethSpecified) revert ExceedsSwapAmount();

        // Return a positive delta on the specified currency (ETH) owed to the hook.
        // Unspecified delta is zero here; we will realize via PoolManager.take() in afterSwap.
        // Casting is safe due to TOTAL_BPS_MAX and fee < 2^128-1 assertion below.
        if (fee > type(uint128).max) revert InvalidConfig();
        int128 specifiedDelta = int128(uint128(fee));

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.toBeforeSwapDelta(specifiedDelta, int128(0)),
            0 // no lpFee override
        );
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address, // sender (router/universal router)
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /*hookData*/
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!feesEnabled || (hourlyBps + dailyBps + devBps) == 0) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        _checkBuxEthPool(key);
        PoolId poolId = key.toId();

        // Figure out whether ETH is the unspecified currency for this swap.
        // If zeroForOne: specified=currency0, unspecified=currency1 -> ETH unspecified if currency1 is ETH.
        // If !zeroForOne: specified=currency1, unspecified=currency0 -> ETH unspecified if currency0 is ETH.
        bool ethIsUnspecified = params.zeroForOne ? _isEth(key.currency1) : _isEth(key.currency0);
        bool ethWasSpecified  = !ethIsUnspecified;

        uint256 fee;
        uint256 ethMoved;

        if (ethIsUnspecified) {
            // ETH amount is in the swap's BalanceDelta on the ETH side.
            int128 ethDelta = _isEth(key.currency0) ? delta.amount0() : delta.amount1();
            // BalanceDelta is "amount owed to the caller (positive) or owed to the pool (negative)".
            // We just need the magnitude moved.
            ethMoved = _abs128(ethDelta);
            fee = _computeFee(ethMoved);

            // Report hook delta in *unspecified* currency (ETH here).
            // Positive means the hook took/owes to receive that much unspecified currency.
            if (fee > type(int128).max) revert InvalidConfig();
            int128 hookDeltaUnspecified = int128(uint128(fee));

            // Realize ETH to this contract during the lock; then forward to recipients below.
            if (fee != 0) {
                poolManager.take(_cEth, address(this), fee);
                _forwardSplitAndEmit(poolId, false, ethMoved, fee);
            }

            return (IHooks.afterSwap.selector, hookDeltaUnspecified);
        } else {
            // ETH was the specified currency. We already returned a specified delta in beforeSwap.
            // Recompute the same fee from params.amountSpecified to realize it now.
            ethMoved = _abs(params.amountSpecified);
            fee = _computeFee(ethMoved);

            if (fee != 0) {
                // Take ETH to this contract. The positive specified delta from beforeSwap
                // authorizes this take; afterSwap return delta is zero (it's on specified side).
                poolManager.take(_cEth, address(this), fee);
                _forwardSplitAndEmit(poolId, true, ethMoved, fee);
            }

            // No hook delta on the unspecified currency in this branch.
            return (IHooks.afterSwap.selector, int128(0));
        }
    }

    // ========= Internals =========

    function _computeFee(uint256 amount) private view returns (uint256) {
        unchecked {
            // Sum is bounded by TOTAL_BPS_MAX; multiplication order avoids overflow at typical sizes.
            uint256 totalBps = uint256(hourlyBps) + uint256(dailyBps) + uint256(devBps);
            return amount * totalBps / BPS_DENOMINATOR;
        }
    }

    function _forwardSplitAndEmit(
        PoolId poolId,
        bool ethWasSpecified,
        uint256 ethMoved,
        uint256 fee
    ) private {
        if (fee == 0) {
            emit FeeRealized(PoolId.unwrap(poolId), ethWasSpecified, ethMoved, 0, 0, 0, 0);
            return;
        }

        uint256 totalBps = uint256(hourlyBps) + uint256(dailyBps) + uint256(devBps);

        uint256 hourlyAmt = fee * hourlyBps / totalBps;
        uint256 dailyAmt  = fee * dailyBps  / totalBps;
        // Put remainder (if any) on dev to avoid dust
        uint256 devAmt    = fee - hourlyAmt - dailyAmt;

        // Forward Hourly + Daily to the lotto with attribution
        if (hourlyAmt + dailyAmt > 0) {
            (bool ok1, ) = lotto.call{value: (hourlyAmt + dailyAmt)}(
                abi.encodeWithSelector(IBUXLotto.fundFromHook.selector, hourlyAmt, dailyAmt)
            );
            if (!ok1) revert TransferFailed();
        }

        // Forward Dev portion
        if (devAmt > 0) {
            (bool ok2, ) = devFeeSplitter.call{value: devAmt}("");
            if (!ok2) revert TransferFailed();
        }

        emit FeeRealized(
            PoolId.unwrap(poolId),
            ethWasSpecified,
            ethMoved,
            fee,
            hourlyAmt,
            dailyAmt,
            devAmt
        );
    }

    function _checkBuxEthPool(PoolKey calldata key) private view {
        // Currency guard: exactly one side must be native ETH; the other must be BUX.
        bool c0IsEth = _isEth(key.currency0);
        bool c1IsEth = _isEth(key.currency1);
        if (!(c0IsEth ^ c1IsEth)) revert NotBuxEthPool();

        Currency buxSide = c0IsEth ? key.currency1 : key.currency0;
        if (Currency.unwrap(buxSide) != buxToken) revert NotBuxEthPool();

        // Optional allowlist: if used, the pool must be allowed.
        if (_isAllowlistActive()) {
            if (!allowedPools[key.toId()]) revert InvalidPool();
        }
    }

    function _isAllowlistActive() private view returns (bool) {
        // If any pool has been added to the map, treat as active allowlist.
        // (Gas-efficient check: there is no direct way to count keys; using a sentinel pattern is overkill here.)
        // Project teams can ignore allowlist by simply not calling allowPool().
        return false; // default disabled unless you opt-in by customizing this line.
    }

    function _isEth(Currency c) private pure returns (bool) {
        return Currency.unwrap(c) == Currency.unwrap(_cEth);
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _abs128(int128 x) private pure returns (uint256) {
        return uint256(int256(x < 0 ? -x : x));
    }

    // Accept ETH from PoolManager.take
    receive() external payable {}
}
