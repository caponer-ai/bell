// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PushFeedGuard} from "./PushFeedGuard.sol";
import {SessionCalendar} from "./SessionCalendar.sol";

/// @title SessionLog
/// @notice A permissionless, append-only record of what the equity feeds said at the bell.
///
/// Every claim about oracle latency on this chain today is a screenshot in somebody's README, ours
/// included. This contract turns the claim into a public record that grows on its own: anyone may call it
/// inside a bounded window around a session boundary, and it writes down what the feed answered at that
/// moment, together with the guard's verdict. First writer wins, nothing can be rewritten, there is no
/// owner and no fee.
///
/// Three marks per feed per trading day:
///   - `markOpen`  inside `[O, O + WINDOW)`: what a contract reading at the opening bell would have seen;
///   - `markFirstPrint` any time in the session: the first observation whose `updatedAt >= O`, which is
///     the feed's first regular-session print, and the delay is measured against the bell itself;
///   - `markClose` inside `[C - WINDOW, C)`: the last state before the exchange closes.
///
/// What this measures is deliberately narrow: the state of a push feed as seen from this chain. It is not
/// a claim about the exchange, and a quiet feed is not a broken one, since these feeds move on a 0.5 %
/// deviation or a 24 h heartbeat. The record simply makes the quiet visible and countable.
contract SessionLog {
    PushFeedGuard public immutable GUARD;

    uint64 public constant WINDOW = 300; // marks are accepted within five minutes of a boundary

    enum Kind {
        OPEN,
        CLOSE
    }

    struct Mark {
        bool set;
        uint8 verdict; // PushFeedGuard.Verdict at the moment of the mark
        uint8 reason; // PushFeedGuard.Reason
        uint32 tradingDate; // YYYYMMDD
        uint64 markedAt; // block time of the mark
        uint64 updatedAt; // feed's own updatedAt
        int192 answer; // feed price, feed decimals
    }

    struct FirstPrint {
        bool set;
        uint32 tradingDate;
        uint64 observedAt; // block time when this contract first saw a regular-session update
        uint64 updatedAt; // the feed's updatedAt of that print
        int192 answer;
    }

    mapping(bytes32 => Mark) private _marks;
    mapping(bytes32 => FirstPrint) private _firstPrints;

    uint256 public totalMarks;
    uint256 public totalFirstPrints;

    event Marked(
        address indexed feed,
        uint32 indexed tradingDate,
        Kind indexed kind,
        uint8 verdict,
        uint8 reason,
        int192 answer,
        uint64 updatedAt,
        uint64 markedAt
    );
    event FirstPrintRecorded(
        address indexed feed,
        uint32 indexed tradingDate,
        uint64 observedAt,
        uint64 updatedAt,
        int192 answer,
        uint64 delayFromOpen
    );

    error NoSession();
    error OutsideMarkWindow();
    error AlreadyMarked();
    error NoFeed();
    error NotYetPrinted();

    constructor(PushFeedGuard guard) {
        GUARD = guard;
    }

    function key(address feed, uint32 tradingDate, Kind kind) public pure returns (bytes32) {
        return keccak256(abi.encode(feed, tradingDate, kind));
    }

    /// @notice Record what `feed` says at the open or the close of the session in progress.
    function mark(address feed, Kind kind) external returns (bytes32 id) {
        uint64 t = uint64(block.timestamp);
        SessionCalendar.Session memory s = SessionCalendar.sessionAt(t);
        if (!s.exists) revert NoSession();
        if (kind == Kind.OPEN) {
            if (t < s.openUtc || t >= s.openUtc + WINDOW) revert OutsideMarkWindow();
        } else {
            if (t + WINDOW < s.closeUtc || t >= s.closeUtc) revert OutsideMarkWindow();
        }

        id = key(feed, s.tradingDate, kind);
        if (_marks[id].set) revert AlreadyMarked();

        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r, int256 answer, uint256 updatedAt) =
            GUARD.check(feed, type(uint64).max); // the record is about the session, not about a budget
        if (r == PushFeedGuard.Reason.NO_FEED) revert NoFeed();

        _marks[id] = Mark({
            set: true,
            verdict: uint8(v),
            reason: uint8(r),
            tradingDate: s.tradingDate,
            markedAt: t,
            updatedAt: uint64(updatedAt),
            // forge-lint: disable-next-line(unsafe-typecast)
            answer: int192(answer)
        });
        totalMarks++;
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Marked(feed, s.tradingDate, kind, uint8(v), uint8(r), int192(answer), uint64(updatedAt), t);
    }

    /// @notice Record the feed's first print of the regular session, and how long after the bell it came.
    /// @dev Callable any time inside the session. Reverts until the feed's own `updatedAt` reaches the
    ///      opening bell, so the stored delay is an upper bound on the true latency: it is the first time
    ///      *someone asked*, never earlier than the print itself.
    function markFirstPrint(address feed) external returns (uint64 delayFromOpen) {
        uint64 t = uint64(block.timestamp);
        SessionCalendar.Session memory s = SessionCalendar.sessionAt(t);
        if (!s.exists) revert NoSession();
        if (t < s.openUtc || t >= s.closeUtc) revert OutsideMarkWindow();

        bytes32 id = keccak256(abi.encode(feed, s.tradingDate));
        if (_firstPrints[id].set) revert AlreadyMarked();

        (, PushFeedGuard.Reason r, int256 answer, uint256 updatedAt) = GUARD.check(feed, type(uint64).max);
        if (r == PushFeedGuard.Reason.NO_FEED) revert NoFeed();
        if (updatedAt < s.openUtc) revert NotYetPrinted();

        delayFromOpen = uint64(updatedAt) - s.openUtc;
        _firstPrints[id] = FirstPrint({
            set: true,
            tradingDate: s.tradingDate,
            observedAt: t,
            updatedAt: uint64(updatedAt),
            // forge-lint: disable-next-line(unsafe-typecast)
            answer: int192(answer)
        });
        totalFirstPrints++;
        // forge-lint: disable-next-line(unsafe-typecast)
        emit FirstPrintRecorded(feed, s.tradingDate, t, uint64(updatedAt), int192(answer), delayFromOpen);
    }

    function getMark(address feed, uint32 tradingDate, Kind kind) external view returns (Mark memory) {
        return _marks[key(feed, tradingDate, kind)];
    }

    function getFirstPrint(address feed, uint32 tradingDate) external view returns (FirstPrint memory) {
        return _firstPrints[keccak256(abi.encode(feed, tradingDate))];
    }

    /// @notice Marks for many feeds of one trading day, for dashboards and for anyone checking our numbers.
    function getMarks(address[] calldata feeds, uint32 tradingDate, Kind kind)
        external
        view
        returns (Mark[] memory out)
    {
        out = new Mark[](feeds.length);
        for (uint256 i = 0; i < feeds.length; i++) {
            out[i] = _marks[key(feeds[i], tradingDate, kind)];
        }
    }

    function getFirstPrints(address[] calldata feeds, uint32 tradingDate)
        external
        view
        returns (FirstPrint[] memory out)
    {
        out = new FirstPrint[](feeds.length);
        for (uint256 i = 0; i < feeds.length; i++) {
            out[i] = _firstPrints[keccak256(abi.encode(feeds[i], tradingDate))];
        }
    }
}
