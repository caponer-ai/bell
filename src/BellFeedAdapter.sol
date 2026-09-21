// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Bell} from "./Bell.sol";

/// @title BellFeedAdapter
/// @notice Chainlink's `latestRoundData()` shape, answered by Bell instead of by a push feed.
///
/// Every contract on this chain that prices a stock token already calls `latestRoundData()` on an
/// aggregator proxy. That call cannot fail and cannot say "the exchange is closed": it returns the last
/// number written, together with the `updatedAt` of that round, and leaves the consumer to decide what
/// either means. This adapter keeps the exact same signature and
/// changes exactly one thing: **when the data is not fit to act on, the call reverts instead of
/// returning a number.**
///
/// Integration is therefore a constructor argument, not a rewrite: point the consumer at this address
/// instead of the feed proxy. The audit in `docs/REPLAY.md` shows what that swap would have done to 30
/// real settlements on this chain: every one of them would have reverted rather than resolving on a
/// price that was a median of 11.9 hours old, on days the exchange never opened.
///
/// Units, stated because mixing them is how oracles kill people: Bell stores mid with **18 decimals**,
/// Chainlink's equity proxies on this chain report **8**. The adapter divides by 1e10 and exposes
/// `decimals() = 8`, so a consumer that already handles a Chainlink equity feed needs no scaling change.
/// `roundId` and `updatedAt` are the report's `observationsTimestamp`: monotonic, and meaningful, unlike
/// a round counter.
///
/// No owner, no upgrade, no state: every answer is derived from Bell at call time.
contract BellFeedAdapter {
    Bell public immutable BELL;
    bytes32 public immutable FEED_ID;
    string private _description;

    uint8 public constant decimals = 8;
    uint256 public constant version = 1;
    int256 private constant SCALE = 1e10; // 18 decimals in Bell -> 8 decimals here

    /// @notice The data exists and is authentic, but Bell refuses it: reason is Bell's `Reason` enum.
    error NotAdmissible(uint8 reason);
    /// @notice Historical rounds are not served: Bell keeps receipts, not a round history.
    error HistoricalRoundsNotSupported();

    constructor(Bell bell, bytes32 feedId, string memory description_) {
        BELL = bell;
        FEED_ID = feedId;
        _description = description_;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    /// @notice Chainlink-shaped read that refuses to answer with an inadmissible price.
    /// @dev Reverts with NotAdmissible when Bell says WAIT or REJECT: stale observation, stale mid,
    ///      unknown or non-regular market status, outside the session, or the issuer paused the token.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (Bell.Verdict verdict, Bell.Reason reason) = BELL.checkLive(FEED_ID);
        if (verdict != Bell.Verdict.ALLOW) revert NotAdmissible(uint8(reason));
        (int192 mid,,, uint32 observationsTimestamp,,,,,) = BELL.latest(FEED_ID);
        // forge-lint: disable-next-line(unsafe-typecast)
        answer = int256(mid) / SCALE;
        roundId = uint80(observationsTimestamp);
        startedAt = observationsTimestamp;
        updatedAt = observationsTimestamp;
        answeredInRound = roundId;
    }

    /// @notice The same read, without reverting, for consumers that prefer a flag to a revert.
    /// @return ok false when Bell refuses; the price fields are then zero.
    function tryLatestRoundData() external view returns (bool ok, uint8 reason, int256 answer, uint256 updatedAt) {
        (Bell.Verdict verdict, Bell.Reason why) = BELL.checkLive(FEED_ID);
        if (verdict != Bell.Verdict.ALLOW) return (false, uint8(why), 0, 0);
        (int192 mid,,, uint32 observationsTimestamp,,,,,) = BELL.latest(FEED_ID);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, 0, int256(mid) / SCALE, observationsTimestamp);
    }

    /// @notice The settlement reference of a trading day, in the same 8-decimal unit.
    /// @dev Reverts until the ladder for that fixing is FINAL, so a settlement cannot run early.
    function sessionReference(uint32 tradingDate, bool isClose)
        external
        view
        returns (int256 answer, uint256 observedAt, bytes32 receiptId)
    {
        (Bell.Verdict verdict, Bell.Reason reason, int192 mid, bytes32 id) =
            BELL.checkSettle(FEED_ID, tradingDate, isClose);
        if (verdict != Bell.Verdict.ALLOW) revert NotAdmissible(uint8(reason));
        Bell.Receipt memory r = BELL.receipt(id);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (int256(mid) / SCALE, r.observationsTimestamp, id);
    }

    /// @notice Historical rounds are intentionally unsupported: ask Bell for a receipt instead.
    function getRoundData(uint80) external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert HistoricalRoundsNotSupported();
    }
}
