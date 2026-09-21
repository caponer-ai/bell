// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SessionCalendar} from "./SessionCalendar.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title PushFeedGuard
/// @notice The session question, asked of the feeds that already exist on this chain.
///
/// Robinhood Chain carries 35 Chainlink push feeds for US equities. They are free to read, they are the
/// price source almost every contract here already uses, and they cannot answer the two questions that
/// decide whether a price may be acted on: **is the exchange open right now**, and **how old is this
/// number**. `latestRoundData()` always succeeds, even at 03:00 UTC on a Sunday.
///
/// This guard is stateless and serves every feed on the chain from one deployment. It combines the
/// NYSE calendar compiled into `SessionCalendar` (DST by rule, holidays and early closes tabulated) with
/// the feed's own `updatedAt`, and returns a verdict a contract can branch on.
///
/// What it does not do, said plainly: it cannot make a push feed fresh. Inside the regular session a
/// feed legitimately goes quiet while the price stays inside its 0.5 % deviation band, so `maxAge` is the
/// caller's risk choice, not a property of the data. A settlement contract will want minutes; a slow
/// collateral check may accept an hour. The guard's contribution is that the choice becomes explicit and
/// the calendar stops being a comment in someone's off-chain keeper.
///
/// No owner, no upgrade, no state, no fee.
contract PushFeedGuard {
    enum Verdict {
        ALLOW,
        WAIT,
        REJECT
    }

    enum Reason {
        OK,
        NO_SESSION, // the calendar has no trading day: weekend, holiday, or a year outside the table
        OUTSIDE_SESSION, // a trading day, but before the open or at/after the close
        PRICE_STALE, // the feed has not updated within maxAge
        ROUND_INCOMPLETE, // updatedAt == 0
        BAD_PRICE, // answer <= 0
        NO_FEED // nothing deployed at that address, or the call reverted
    }

    error NotAdmissible(uint8 reason);

    /// @notice Verdict for `feed` at the current block time, with `maxAge` seconds of tolerated staleness.
    function check(address feed, uint64 maxAge)
        public
        view
        returns (Verdict verdict, Reason reason, int256 answer, uint256 updatedAt)
    {
        (bool ok, int256 a, uint256 u) = _read(feed);
        if (!ok) return (Verdict.REJECT, Reason.NO_FEED, 0, 0);
        if (u == 0) return (Verdict.REJECT, Reason.ROUND_INCOMPLETE, a, u);
        if (a <= 0) return (Verdict.REJECT, Reason.BAD_PRICE, a, u);

        uint64 t = uint64(block.timestamp);
        // A price stamped in the future is not a fresher price, it is a broken round: an arbitrary
        // address can claim any updatedAt, and without this an attacker-supplied "feed" would look
        // permanently fresh to every consumer that trusts this guard.
        if (u > uint256(t) + 2) return (Verdict.REJECT, Reason.ROUND_INCOMPLETE, a, u);
        SessionCalendar.Session memory s = SessionCalendar.sessionAt(t);
        if (!s.exists) return (Verdict.REJECT, Reason.NO_SESSION, a, u);
        if (t < s.openUtc || t >= s.closeUtc) return (Verdict.REJECT, Reason.OUTSIDE_SESSION, a, u);
        if (u + maxAge < t) return (Verdict.WAIT, Reason.PRICE_STALE, a, u);
        return (Verdict.ALLOW, Reason.OK, a, u);
    }

    /// @notice Chainlink-shaped read that refuses instead of answering with an inadmissible price.
    function latestRoundData(address feed, uint64 maxAge)
        external
        view
        returns (int256 answer, uint256 updatedAt, uint256 age)
    {
        (Verdict v, Reason reason, int256 a, uint256 u) = check(feed, maxAge);
        if (v != Verdict.ALLOW) revert NotAdmissible(uint8(reason));
        return (a, u, block.timestamp - u);
    }

    /// @notice Verdicts for many feeds in one call, for dashboards and for anyone auditing the chain.
    function checkMany(address[] calldata feeds, uint64 maxAge)
        external
        view
        returns (Verdict[] memory verdicts, Reason[] memory reasons, int256[] memory answers, uint256[] memory ages)
    {
        verdicts = new Verdict[](feeds.length);
        reasons = new Reason[](feeds.length);
        answers = new int256[](feeds.length);
        ages = new uint256[](feeds.length);
        for (uint256 i = 0; i < feeds.length; i++) {
            (Verdict v, Reason r, int256 a, uint256 u) = check(feeds[i], maxAge);
            verdicts[i] = v;
            reasons[i] = r;
            answers[i] = a;
            ages[i] = u == 0 ? 0 : block.timestamp - u;
        }
    }

    /// @notice The session the calendar sees at `timestamp`: exists, open, close, trading date.
    function sessionAt(uint64 timestamp) external pure returns (SessionCalendar.Session memory) {
        return SessionCalendar.sessionAt(timestamp);
    }

    /// @notice Session bounds of a trading date (YYYYMMDD), for schedulers and keepers.
    function sessionForDate(uint32 tradingDate) external pure returns (SessionCalendar.Session memory) {
        return SessionCalendar.sessionForDate(tradingDate);
    }

    function _read(address feed) internal view returns (bool ok, int256 answer, uint256 updatedAt) {
        if (feed.code.length == 0) return (false, 0, 0);
        (bool success, bytes memory data) =
            feed.staticcall(abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector));
        if (!success || data.length < 160) return (false, 0, 0);
        (, int256 a,, uint256 u,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        return (true, a, u);
    }
}

/// @notice One feed bound to one staleness budget, exposing the exact Chainlink signature, so an
///         existing consumer integrates by changing a single address in its constructor.
contract GuardedPushFeed {
    PushFeedGuard public immutable GUARD;
    address public immutable FEED;
    uint64 public immutable MAX_AGE;

    constructor(PushFeedGuard guard, address feed, uint64 maxAge) {
        GUARD = guard;
        FEED = feed;
        MAX_AGE = maxAge;
    }

    function decimals() external view returns (uint8) {
        return IAggregatorV3(FEED).decimals();
    }

    function description() external view returns (string memory) {
        return IAggregatorV3(FEED).description();
    }

    /// @dev Reverts with PushFeedGuard.NotAdmissible when the session is closed or the price is stale.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        (int256 a, uint256 u,) = GUARD.latestRoundData(FEED, MAX_AGE);
        roundId = uint80(u);
        return (roundId, a, u, u, roundId);
    }

    /// @notice Same read without a revert: ok == false carries the reason instead.
    function tryLatestRoundData() external view returns (bool ok, uint8 reason, int256 answer, uint256 updatedAt) {
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r, int256 a, uint256 u) = GUARD.check(FEED, MAX_AGE);
        return (v == PushFeedGuard.Verdict.ALLOW, uint8(r), a, u);
    }
}
