// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PushFeedGuard} from "../src/PushFeedGuard.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";

/// The demo, run against the real deployment on mainnet rather than against a mock.
///
/// Everything here talks to `PushFeedGuard` at 0x8aF68a9fF7583097A7476060C6B56eB33dA7a711 on chainId 4663
/// and to the real Chainlink equity feeds. Nothing is stubbed: the only thing the test controls is the
/// clock, which is the whole point, because the question this project asks is what the same feed means at
/// different hours.
///
///     forge test --fork-url robinhood --match-path "test/DemoFork.t.sol" -vv
///
/// The printed transcript is the shot for the video: one feed, one address, four moments, four answers.
contract DemoForkTest is Test {
    PushFeedGuard constant GUARD = PushFeedGuard(0x8aF68a9fF7583097A7476060C6B56eB33dA7a711);

    address constant AAPL = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant SPY = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address constant NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    uint64 constant BUDGET = 900; // fifteen minutes, a settlement-grade budget

    // The moments are taken from the fork's own clock, never hard-coded: the next regular session that has
    // not opened yet, and the Saturday after the fork block at 17:00 UTC. A fixed date would put the clock
    // behind the fork once that date has passed, and every feed would then look like it printed in the future.
    uint64 internal TUE_OPEN;
    uint64 internal TUE_CLOSE;
    uint32 internal TRADING_DATE;
    uint64 internal SATURDAY;

    string[3] private NAMES = ["AAPL", "SPY", "NVDA"];

    function setUp() public {
        vm.skip(address(GUARD).code.length == 0);
        uint64 nowTs = uint64(block.timestamp);
        for (uint64 k = 0; k < 10; k++) {
            SessionCalendar.Session memory s = SessionCalendar.sessionAt(nowTs + k * 1 days);
            if (s.exists && s.openUtc > nowTs + 60) {
                (TUE_OPEN, TUE_CLOSE, TRADING_DATE) = (s.openUtc, s.closeUtc, s.tradingDate);
                break;
            }
        }
        uint64 day = nowTs / 1 days;
        uint64 dow = (day + 4) % 7; // 1970-01-01 was a Thursday; 0 is Sunday
        uint64 ahead = (6 + 7 - dow) % 7;
        if (ahead == 0 && nowTs % 1 days >= 17 hours) ahead = 7;
        SATURDAY = (day + ahead) * 1 days + 17 hours;
    }

    function _feeds() internal pure returns (address[3] memory) {
        return [AAPL, SPY, NVDA];
    }

    function _verdict(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "ALLOW ";
        if (v == 1) return "WAIT  ";
        return "REJECT";
    }

    function _reason(uint8 r) internal pure returns (string memory) {
        if (r == 0) return "OK";
        if (r == 1) return "NO_SESSION";
        if (r == 2) return "OUTSIDE_SESSION";
        if (r == 3) return "PRICE_STALE";
        if (r == 4) return "ROUND_INCOMPLETE";
        if (r == 5) return "BAD_PRICE";
        return "NO_FEED";
    }

    function _show(string memory when, uint64 at) internal {
        vm.warp(at);
        console.log("");
        console.log(when);
        address[3] memory feeds = _feeds();
        for (uint256 i = 0; i < 3; i++) {
            (PushFeedGuard.Verdict v, PushFeedGuard.Reason r,, uint256 updatedAt) = GUARD.check(feeds[i], BUDGET);
            uint256 age = at > updatedAt ? at - updatedAt : 0;
            console.log(
                string.concat(
                    "  ",
                    NAMES[i],
                    "  ",
                    _verdict(uint8(v)),
                    "  ",
                    _reason(uint8(r)),
                    "  price age ",
                    vm.toString(age / 60),
                    " min"
                )
            );
        }
    }

    /// The transcript. Same contract, same feeds, four moments.
    function test_the_same_feed_at_four_different_hours() public {
        console.log("PushFeedGuard 0x8aF68a9fF7583097A7476060C6B56eB33dA7a711, budget 900 s");
        console.log("next regular session after the fork block: trading date", TRADING_DATE);
        _show("One minute before the bell:", TUE_OPEN - 60);
        _show("Five minutes after the bell:", TUE_OPEN + 300);
        _show("One minute after that day's close:", TUE_CLOSE + 60);
        _show("The following Saturday, 17:00 UTC, the exchange shut since Friday:", SATURDAY);
    }

    /// The assertion behind the transcript, so this is a test and not a print statement.
    function test_the_guard_refuses_outside_the_session_and_admits_inside_it() public {
        address[3] memory feeds = _feeds();

        vm.warp(SATURDAY);
        for (uint256 i = 0; i < 3; i++) {
            (PushFeedGuard.Verdict v, PushFeedGuard.Reason r,,) = GUARD.check(feeds[i], BUDGET);
            assertTrue(v != PushFeedGuard.Verdict.ALLOW, "a Saturday price is not admissible");
            assertEq(uint8(r), uint8(PushFeedGuard.Reason.NO_SESSION), "and the reason names the day");
        }

        vm.warp(TUE_OPEN - 60);
        for (uint256 i = 0; i < 3; i++) {
            (PushFeedGuard.Verdict v, PushFeedGuard.Reason r,,) = GUARD.check(feeds[i], BUDGET);
            assertTrue(v != PushFeedGuard.Verdict.ALLOW, "one minute before the bell is still outside");
            assertEq(uint8(r), uint8(PushFeedGuard.Reason.OUTSIDE_SESSION));
        }

        // Inside the session the verdict depends on the feed's own freshness, which is the caller's risk
        // budget and not a property of the calendar. What must hold is that the session objection is gone.
        vm.warp(TUE_OPEN + 300);
        for (uint256 i = 0; i < 3; i++) {
            (, PushFeedGuard.Reason r,,) = GUARD.check(feeds[i], BUDGET);
            assertTrue(
                r != PushFeedGuard.Reason.NO_SESSION && r != PushFeedGuard.Reason.OUTSIDE_SESSION,
                "inside the session the calendar no longer objects"
            );
        }
    }

    /// The honest half of the demo: the guard cannot make a quiet feed talk. Five minutes after the bell a
    /// feed that has not published since yesterday is refused for being old, not for being out of session,
    /// and no amount of calendar logic changes that.
    function test_inside_the_session_a_quiet_feed_is_still_refused() public {
        vm.warp(TUE_OPEN + 300);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r,, uint256 updatedAt) = GUARD.check(AAPL, 60);
        if (TUE_OPEN + 300 - updatedAt > 60) {
            assertTrue(v != PushFeedGuard.Verdict.ALLOW, "a one-minute budget is not met by a quiet feed");
            assertEq(uint8(r), uint8(PushFeedGuard.Reason.PRICE_STALE), "and the reason is age, not the calendar");
        }
    }

    /// The calendar half, with no network at all: the three days of 2026 the exchange closes early, and the
    /// Thanksgiving holiday next to one of them.
    function test_the_calendar_knows_the_half_days() public pure {
        SessionCalendar.Session memory blackFriday = SessionCalendar.sessionForDate(20261127);
        assertTrue(blackFriday.exists && blackFriday.earlyClose, "day after Thanksgiving is a half day");
        assertEq(blackFriday.closeUtc - blackFriday.openUtc, 3 hours + 30 minutes);

        assertFalse(SessionCalendar.sessionForDate(20261126).exists, "Thanksgiving itself is closed");

        SessionCalendar.Session memory normal = SessionCalendar.sessionForDate(20261123);
        assertEq(normal.closeUtc - normal.openUtc, 6 hours + 30 minutes, "a full session for contrast");
    }
}
