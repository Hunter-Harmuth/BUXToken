// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title BUXLotto
 * @notice ETH-only lottery treasury with automated hourly and daily drawings funded by a Uniswap v4 hook.
 *         Winners are selected via a SortitionIndex weighted by BUX balances. Payouts are AUTOMATIC and
 *         **restricted to EOAs only** (wallets, not contracts). Ineligible winners or failed sends roll
 *         prizes back into the pot. Draw requests are anchored (24 hourly + 1 daily) and use Chainlink VRF.
 *
 *         Key properties:
 *           - ETH treasury only (no selling BUX to pay winners).
 *           - Hourly pot & Daily pot accrue from the Hook via `fundFromHook(...)`.
 *           - Anchored cadence: exactly once per hour and once per day (UTC), with anchors advanced
 *             immediately when a request is made (prevents backlog).
 *           - VRF callback includes a tiny reentrancy lock; `performUpkeep` is nonReentrant.
 *           - Eligibility enforced by token + EOA-only payout. If the candidate is ineligible or a send
 *             fails, the pot remains and rolls forward.
 *
 *         Admin:
 *           - Owner can pause/unpause draws and update hook address, min hourly prize, and VRF callback gas.
 *           - Protocol addresses (Safe, Lotto, Hook, Splitter) should be set pause-exempt at the system level.
 */

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/*//////////////////////////////////////////////////////////////
                          LIGHTWEIGHT IFACES
//////////////////////////////////////////////////////////////*/

interface ISortitionIndex {
    function totalWeight() external view returns (uint256);
    function drawByUint(uint256 randomValue) external view returns (address);
}


interface IBUXToken {
    function isEligible(address account) external view returns (bool);
}

/*//////////////////////////////////////////////////////////////
                          MAIN CONTRACT
//////////////////////////////////////////////////////////////*/

contract BUXLotto is Ownable, Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error ZeroAddress();
    error OnlyHook();
    error RequestAlreadyPending();
    error NothingToDo();
    error BadFundingSplit();
    error BadCallback();
    error TooManyWords();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event HookUpdated(address indexed hook);
    event MinHourlyPrizeUpdated(uint256 oldWei, uint256 newWei);
    event CallbackGasLimitUpdated(uint32 oldGas, uint32 newGas);

    event FundedFromHook(uint256 hourlyWei, uint256 dailyWei, uint256 newHourlyPot, uint256 newDailyPot);

    event HourlyDrawRequested(uint256 indexed requestId, uint64 roundId, uint64 nextAnchor);
    event DailyDrawRequested(uint256 indexed requestId, uint64 roundId, uint64 nextAnchor);

    event HourlyWinnerPaid(uint64 indexed roundId, address indexed winner, uint256 prizeWei, string note);
    event DailyWinnerPaid(uint64 indexed roundId, address indexed winner, uint256 prizeWei, string note);

    event DrawSkipped(string drawType, string reason, uint64 roundId, uint256 potWei, uint256 totalWeight);
    event WinnerIneligible(string drawType, uint64 roundId, address candidate, uint256 prizeWei, string reason);
    event WinnerDeferred(string drawType, uint64 roundId, address candidate, uint256 prizeWei, string reason);

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    ISortitionIndex public immutable index;
    IBUXToken public immutable token;

    // Chainlink VRF v2.5 (Plus) / native payments
    IVRFCoordinatorV2Plus public immutable vrfCoordinator;

    bytes32 public immutable keyHash;           // VRF key hash
    uint256 public immutable vrfSubId;         // VRF subscription id
    uint16  public immutable vrfMinConfs;      // VRF minimum confirmations
    uint32  public callbackGasLimit;            // VRF callback gas (owner-settable)
    uint32  public constant VRF_NUM_WORDS = 1;  // 1 random word per draw

    address public hook;                        // Uniswap v4 funding hook (trusted sender for funds)
    uint256 public minHourlyPrizeWei;           // Skip hourly if below this threshold

    /*//////////////////////////////////////////////////////////////
                                STATE
    //////////////////////////////////////////////////////////////*/

    // Pots
    uint256 public hourlyPotWei;
    uint256 public dailyPotWei;

    // Anchors and round counters
    uint64  public nextHourlyAt;                // unix seconds, top of next hour UTC
    uint64  public nextDailyAt;                 // unix seconds, start of next UTC day (00:00)
    uint64  public hourlyRoundId;               // incremented when scheduling a request
    uint64  public dailyRoundId;                // incremented when scheduling a request

    // Pending flags so we never double-request within the same round
    bool public hourlyPending;
    bool public dailyPending;

    enum DrawType { HOURLY, DAILY }
    struct RequestInfo {
        DrawType drawType;
        uint64   roundId;
        bool     used;
    }
    mapping(uint256 => RequestInfo) public requests;

    // Tiny callback lock to make fulfillment provably non-reentrant from inside the contract.
    bool private _inFulfill;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param initialOwner       Gnosis Safe (recommended) or deployer to be transferred to Safe
     * @param index_             SortitionIndex address (weighted picker)
     * @param token_             BUXToken address (for isEligible double-check)
     * @param vrfCoordinator_    Chainlink VRF Coordinator (v2.5)
     * @param keyHash_           Chainlink keyHash
     * @param subId_             Chainlink subscription id
     * @param minConfs_          Chainlink min confirmations
     * @param callbackGas_       Initial callback gas limit
     * @param minHourlyWei_      Minimum hourly prize to avoid dust payouts
     */
    constructor(
        address initialOwner,
        address index_,
        address token_,
        address vrfCoordinator_,
        bytes32 keyHash_,
        uint256 subId_,
        uint16  minConfs_,
        uint32  callbackGas_,
        uint256 minHourlyWei_
    ) Ownable(initialOwner) VRFConsumerBaseV2Plus(vrfCoordinator_) {
        if (index_ == address(0) || token_ == address(0) || vrfCoordinator_ == address(0)) revert ZeroAddress();

        index           = ISortitionIndex(index_);
        token           = IBUXToken(token_);
        vrfCoordinator  = IVRFCoordinatorV2Plus(vrfCoordinator_);
        keyHash         = keyHash_;
        vrfSubId        = subId_;
        vrfMinConfs     = minConfs_;
        callbackGasLimit = callbackGas_;
        minHourlyPrizeWei = minHourlyWei_;

        // Initialize anchors to the next aligned hour and day (UTC).
        uint64 nowTs = uint64(block.timestamp);
        nextHourlyAt = _ceilToNextHour(nowTs);
        nextDailyAt  = _ceilToNextDay(nowTs);
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    modifier notInFulfill() {
        if (_inFulfill) revert BadCallback();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function pauseLottery() external onlyOwner {
        _pause();
    }

    function unpauseLottery() external onlyOwner {
        _unpause();
    }

    /// @notice Set/replace the funding hook address.
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookUpdated(hook_);
    }

    /// @notice Update minimum hourly prize (dust guard).
    function setMinHourlyPrizeWei(uint256 newMin) external onlyOwner {
        uint256 old = minHourlyPrizeWei;
        minHourlyPrizeWei = newMin;
        emit MinHourlyPrizeUpdated(old, newMin);
    }

    /// @notice Update VRF callback gas limit.
    function setCallbackGasLimit(uint32 newGas) external onlyOwner {
        uint32 old = callbackGasLimit;
        callbackGasLimit = newGas;
        emit CallbackGasLimitUpdated(old, newGas);
    }

    /*//////////////////////////////////////////////////////////////
                             FUNDING ENTRYPOINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Called by the Uniswap v4 hook to forward ETH into the Hourly and Daily pots.
     * @dev    The hook must pass the exact split; this function checks `hourly + daily == msg.value`.
     */
    function fundFromHook(uint256 hourlyWei, uint256 dailyWei) external payable onlyHook whenNotPaused {
        if (hourlyWei + dailyWei != msg.value) revert BadFundingSplit();
        if (hourlyWei > 0) hourlyPotWei += hourlyWei;
        if (dailyWei  > 0) dailyPotWei  += dailyWei;
        emit FundedFromHook(hourlyWei, dailyWei, hourlyPotWei, dailyPotWei);
    }

    /*//////////////////////////////////////////////////////////////
                         AUTOMATION / SCHEDULING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice External automation entrypoint. Schedules hourly and/or daily draws if due.
     * @dev    We advance anchors immediately upon scheduling so backlogs cannot accumulate.
     */
    function performUpkeep() external whenNotPaused nonReentrant notInFulfill {
        uint64 nowTs = uint64(block.timestamp);
        bool didSomething;

        // Hourly draw scheduling
        if (!hourlyPending && nowTs >= nextHourlyAt) {
            if (hourlyPotWei >= minHourlyPrizeWei && hourlyPotWei > 0) {
                hourlyRoundId += 1;
                uint256 reqId = _requestVRF(DrawType.HOURLY, hourlyRoundId);
                hourlyPending = true;

                // Advance to next hour anchor immediately (top of the next hour)
                nextHourlyAt = _ceilToNextHour(nowTs);
                emit HourlyDrawRequested(reqId, hourlyRoundId, nextHourlyAt);
                didSomething = true;
            } else {
                // No sufficient pot; skip scheduling but still advance anchor to avoid backlog
                uint64 skippedRound = ++hourlyRoundId;
                nextHourlyAt = _ceilToNextHour(nowTs);
                emit DrawSkipped("hourly", "insufficient_pot", skippedRound, hourlyPotWei, index.totalWeight());
                didSomething = true;
            }
        }

        // Daily draw scheduling
        if (!dailyPending && nowTs >= nextDailyAt) {
            if (dailyPotWei > 0) {
                dailyRoundId += 1;
                uint256 reqId2 = _requestVRF(DrawType.DAILY, dailyRoundId);
                dailyPending = true;

                // Advance to next day anchor immediately (00:00 UTC of following day)
                nextDailyAt = _ceilToNextDay(nowTs);
                emit DailyDrawRequested(reqId2, dailyRoundId, nextDailyAt);
                didSomething = true;
            } else {
                uint64 skippedDaily = ++dailyRoundId;
                nextDailyAt = _ceilToNextDay(nowTs);
                emit DrawSkipped("daily", "insufficient_pot", skippedDaily, dailyPotWei, index.totalWeight());
                didSomething = true;
            }
        }

        if (!didSomething) revert NothingToDo();
    }

    /*//////////////////////////////////////////////////////////////
                           VRF: REQUEST / FULFILL
    //////////////////////////////////////////////////////////////*/

    function _requestVRF(DrawType t, uint64 roundId) internal returns (uint256 reqId) {
        // 1 random word per draw via VRF v2.5 (native payment)
        reqId = vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: vrfSubId,
                requestConfirmations: vrfMinConfs,
                callbackGasLimit: callbackGasLimit,
                numWords: VRF_NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: true})
                )
            })
        );
        requests[reqId] = RequestInfo({drawType: t, roundId: roundId, used: true});
    }

    /**
     * @dev Chainlink Coordinator callback. We include a tiny internal lock to make this
     *      provably non-reentrant from inside the contract. External reentrancy is prevented
     *      by payout being EOAs-only (no code to run on receive).
     *
     *      NOTE: In v2.5 the Coordinator calls rawFulfillRandomWords on the base,
     *      which then dispatches to this override. No manual msg.sender check is needed.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        if (_inFulfill) revert BadCallback();
        if (randomWords.length != 1) revert TooManyWords();
        RequestInfo memory info = requests[requestId];
        if (!info.used) revert BadCallback();

        _inFulfill = true;
        // Select and pay winner (or skip) based on type
        if (info.drawType == DrawType.HOURLY) {
            _settleHourly(info.roundId, randomWords[0]);
            hourlyPending = false;
        } else {
            _settleDaily(info.roundId, randomWords[0]);
            dailyPending = false;
        }
        _inFulfill = false;

        // Gas tip: delete to save a bit of storage if desired
        delete requests[requestId];
    }

    function _settleHourly(uint64 roundId, uint256 rnd) internal {
        uint256 pot = hourlyPotWei;
        if (pot == 0) {
            emit DrawSkipped("hourly", "zero_pot_on_fulfill", roundId, pot, index.totalWeight());
            hourlyPending = false;
            return;
        }

        uint256 tw = index.totalWeight();
        if (tw == 0) {
            emit DrawSkipped("hourly", "zero_total_weight", roundId, pot, tw);
            return; // keep pot; it rolls forward
        }

        address winner = index.drawByUint(rnd);

        // Double-defense: winner must be an EOA and currently eligible.
        if (!_isEOA(winner)) {
            emit WinnerIneligible("hourly", roundId, winner, pot, "non_eoa_winner");
            return; // keep pot; it rolls to next hour naturally
        }
        if (!token.isEligible(winner)) {
            emit WinnerIneligible("hourly", roundId, winner, pot, "token_ineligible");
            return;
        }

        // Effects first (CEI): decrement pot, then perform the external call.
        hourlyPotWei = 0;

        (bool sent, ) = payable(winner).call{value: pot}("");
        if (sent) {
            emit HourlyWinnerPaid(roundId, winner, pot, "push_ok");
        } else {
            // Roll back into the pot if the send failed (unlikely for EOAs; preserves funds).
            hourlyPotWei += pot;
            emit WinnerDeferred("hourly", roundId, winner, pot, "send_failed_rolled");
        }
    }

    function _settleDaily(uint64 roundId, uint256 rnd) internal {
        uint256 pot = dailyPotWei;
        if (pot == 0) {
            emit DrawSkipped("daily", "zero_pot_on_fulfill", roundId, pot, index.totalWeight());
            dailyPending = false;
            return;
        }

        uint256 tw = index.totalWeight();
        if (tw == 0) {
            emit DrawSkipped("daily", "zero_total_weight", roundId, pot, tw);
            return; // keep pot; it rolls forward
        }

        address winner = index.drawByUint(rnd);

        if (!_isEOA(winner)) {
            emit WinnerIneligible("daily", roundId, winner, pot, "non_eoa_winner");
            return;
        }
        if (!token.isEligible(winner)) {
            emit WinnerIneligible("daily", roundId, winner, pot, "token_ineligible");
            return;
        }

        // Effects first (CEI)
        dailyPotWei = 0;

        (bool sent, ) = payable(winner).call{value: pot}("");
        if (sent) {
            emit DailyWinnerPaid(roundId, winner, pot, "push_ok");
        } else {
            dailyPotWei += pot;
            emit WinnerDeferred("daily", roundId, winner, pot, "send_failed_rolled");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isEOA(address a) internal view returns (bool) {
        return a.code.length == 0;
    }

    function secondsToNextHourly() external view returns (uint64) {
        uint64 nowTs = uint64(block.timestamp);
        return nextHourlyAt > nowTs ? (nextHourlyAt - nowTs) : 0;
    }

    function secondsToNextDaily() external view returns (uint64) {
        uint64 nowTs = uint64(block.timestamp);
        return nextDailyAt > nowTs ? (nextDailyAt - nowTs) : 0;
    }

    function _ceilToNextHour(uint64 t) internal pure returns (uint64) {
        unchecked {
            uint64 h = (t / 3600) * 3600;
            return h == t ? t + 3600 : h + 3600;
        }
    }

    function _ceilToNextDay(uint64 t) internal pure returns (uint64) {
        unchecked {
            uint64 d = (t / 86400) * 86400;
            return d == t ? t + 86400 : d + 86400;
        }
    }

    /*//////////////////////////////////////////////////////////////
                               RECEIVE / PAUSE
    //////////////////////////////////////////////////////////////*/

    receive() external payable {
        // No-op; funds should come via hook with explicit split.
    }

    /*//////////////////////////////////////////////////////////////
                               SAFETY VALVES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency sweep to owner for unexpected ETH held outside pots.
     * @dev    Normal flows keep ETH only in pots; this is a last-resort admin valve while paused.
     */
    function rescueETH(uint256 amount, address payable to) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "rescue failed");
    }
}
