// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PushFeedGuard, GuardedPushFeed} from "../src/PushFeedGuard.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";

/// A Chainlink push aggregator, as they behave on this chain: always answers, never says why.
contract MockAggregator {
    uint8 public constant decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(int256 a, uint256 u) {
        answer = a;
        updatedAt = u;
        roundId = 1;
    }

    function description() external pure returns (string memory) {
        return "Robinhood AAPL / USD";
    }

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
        roundId++;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

/// A contract that reverts on the read, to prove the guard treats a broken feed as REJECT, not as a price.
contract BrokenAggregator {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("down");
    }
}

/// Trading day used throughout: 2026-09-22 (Tuesday, EDT). O = 13:30:00 UTC, C = 20:00:00 UTC.
contract PushFeedGuardTest is Test {
    PushFeedGuard guard;
    MockAggregator feed;

    uint64 constant O = 1790083800; // 2026-09-22 13:30:00 UTC
    uint64 constant C = 1790107200; // 2026-09-22 20:00:00 UTC
    uint64 constant MAX_AGE = 900; // 15 minutes, the caller's risk choice
    int256 constant PRICE = 31325735000; // 313.25735 with 8 decimals

    function setUp() public {
        guard = new PushFeedGuard();
        feed = new MockAggregator(PRICE, O + 60);
    }

    function _check(uint64 at) internal returns (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) {
        vm.warp(at);
        (v, r,,) = guard.check(address(feed), MAX_AGE);
    }

    // ------------------------------------------------------------------
    // The answer the push feed cannot give on its own
    // ------------------------------------------------------------------
    function test_allows_inside_the_session_with_a_fresh_price() public {
        feed.set(PRICE, O + 600);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(O + 700);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.ALLOW));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.OK));
    }

    function test_rejects_before_the_opening_bell() public {
        feed.set(PRICE, O - 120);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(O - 60);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.OUTSIDE_SESSION), "one minute before the bell");
    }

    function test_rejects_one_second_after_the_closing_bell() public {
        feed.set(PRICE, C - 30);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(C);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.OUTSIDE_SESSION), "the close is exclusive");
    }

    function test_rejects_on_a_weekend() public {
        feed.set(PRICE, 1790434740);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(1790434800); // 2026-09-26 15:00 UTC, Saturday
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.NO_SESSION));
    }

    /// Thanksgiving 2026-11-26: a weekday the exchange does not open.
    function test_rejects_on_an_nyse_holiday() public {
        uint64 thanksgivingNoon = 1795708800; // 2026-11-26 16:00:00 UTC, Thanksgiving Thursday
        feed.set(PRICE, thanksgivingNoon - 60);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(thanksgivingNoon);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.NO_SESSION), "holiday, not just a quiet day");
    }

    // ------------------------------------------------------------------
    // Staleness is the caller's budget, and the guard is explicit about it
    // ------------------------------------------------------------------
    function test_waits_when_the_feed_has_gone_quiet_past_the_budget() public {
        feed.set(PRICE, O + 60);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(O + 60 + MAX_AGE + 1);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.WAIT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.PRICE_STALE));
    }

    function test_exactly_at_the_budget_is_still_admissible() public {
        feed.set(PRICE, O + 60);
        (PushFeedGuard.Verdict v,) = _check(O + 60 + MAX_AGE);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.ALLOW), "boundary is inclusive");
    }

    function test_a_tighter_budget_refuses_what_a_looser_one_allows() public {
        feed.set(PRICE, O + 60);
        vm.warp(O + 360); // five minutes later
        (PushFeedGuard.Verdict loose,,,) = guard.check(address(feed), 900);
        (PushFeedGuard.Verdict tight,,,) = guard.check(address(feed), 60);
        assertEq(uint256(loose), uint256(PushFeedGuard.Verdict.ALLOW));
        assertEq(uint256(tight), uint256(PushFeedGuard.Verdict.WAIT), "the budget is the caller's, not ours");
    }

    // ------------------------------------------------------------------
    // Bad data is refused, never passed through
    // ------------------------------------------------------------------
    function test_rejects_a_non_positive_price() public {
        feed.set(0, O + 60);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(O + 90);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.BAD_PRICE));
    }

    function test_rejects_an_incomplete_round() public {
        feed.set(PRICE, 0);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r) = _check(O + 90);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.ROUND_INCOMPLETE));
    }

    function test_rejects_an_address_with_no_code() public {
        vm.warp(O + 90);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r,,) = guard.check(address(0xdead), MAX_AGE);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.NO_FEED));
    }

    function test_a_reverting_feed_is_refused_not_propagated() public {
        BrokenAggregator broken = new BrokenAggregator();
        vm.warp(O + 90);
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r,,) = guard.check(address(broken), MAX_AGE);
        assertEq(uint256(v), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(uint256(r), uint256(PushFeedGuard.Reason.NO_FEED), "a broken feed must not look like a price");
    }

    // ------------------------------------------------------------------
    // Many feeds at once, which is how the chain actually looks
    // ------------------------------------------------------------------
    function test_checkMany_answers_per_feed() public {
        MockAggregator fresh = new MockAggregator(PRICE, O + 600);
        MockAggregator quiet = new MockAggregator(PRICE, O - 7200);
        BrokenAggregator broken = new BrokenAggregator();
        address[] memory feeds = new address[](3);
        feeds[0] = address(fresh);
        feeds[1] = address(quiet);
        feeds[2] = address(broken);

        vm.warp(O + 700);
        (PushFeedGuard.Verdict[] memory v, PushFeedGuard.Reason[] memory r,, uint256[] memory ages) =
            guard.checkMany(feeds, MAX_AGE);
        assertEq(uint256(v[0]), uint256(PushFeedGuard.Verdict.ALLOW));
        assertEq(uint256(v[1]), uint256(PushFeedGuard.Verdict.WAIT));
        assertEq(uint256(r[1]), uint256(PushFeedGuard.Reason.PRICE_STALE));
        assertEq(uint256(v[2]), uint256(PushFeedGuard.Verdict.REJECT));
        assertEq(ages[0], 100, "age of the fresh feed in seconds");
    }

    // ------------------------------------------------------------------
    // The drop-in wrapper: same signature, one address change for a consumer
    // ------------------------------------------------------------------
    function test_wrapper_returns_the_price_inside_the_session() public {
        GuardedPushFeed wrapped = new GuardedPushFeed(guard, address(feed), MAX_AGE);
        feed.set(PRICE, O + 600);
        vm.warp(O + 700);
        (, int256 answer,, uint256 updatedAt,) = wrapped.latestRoundData();
        assertEq(answer, PRICE);
        assertEq(updatedAt, O + 600);
        assertEq(wrapped.decimals(), 8);
        assertEq(wrapped.description(), "Robinhood AAPL / USD");
    }

    function test_wrapper_reverts_outside_the_session() public {
        GuardedPushFeed wrapped = new GuardedPushFeed(guard, address(feed), MAX_AGE);
        feed.set(PRICE, C - 30);
        vm.warp(C + 1);
        vm.expectRevert(abi.encodeWithSelector(PushFeedGuard.NotAdmissible.selector, uint8(2))); // OUTSIDE_SESSION
        wrapped.latestRoundData();
    }

    function test_wrapper_try_variant_reports_the_reason() public {
        GuardedPushFeed wrapped = new GuardedPushFeed(guard, address(feed), MAX_AGE);
        feed.set(PRICE, C - 30);
        vm.warp(C + 1);
        (bool ok, uint8 reason,,) = wrapped.tryLatestRoundData();
        assertFalse(ok);
        assertEq(reason, 2, "OUTSIDE_SESSION");
    }

    // ------------------------------------------------------------------
    // Calendar views the keeper schedules on
    // ------------------------------------------------------------------
    function test_session_bounds_are_the_ones_the_calendar_publishes() public view {
        SessionCalendar.Session memory s = guard.sessionForDate(20260922);
        assertTrue(s.exists);
        assertEq(s.tradingDate, 20260922);
        assertEq(s.openUtc, O);
        assertEq(s.closeUtc, C);
        assertFalse(s.earlyClose);
    }

    function test_early_close_day_is_shorter() public view {
        SessionCalendar.Session memory s = guard.sessionForDate(20261127); // day after Thanksgiving
        assertTrue(s.exists);
        assertTrue(s.earlyClose);
        assertEq(s.closeUtc - s.openUtc, 3 hours + 30 minutes, "13:00 ET close");
    }

    function test_calendar_agrees_with_the_guard_at_a_boundary_second() public {
        SessionCalendar.Session memory s = guard.sessionForDate(20260922);
        feed.set(PRICE, s.openUtc);
        vm.warp(s.openUtc);
        (PushFeedGuard.Verdict atOpen,,,) = guard.check(address(feed), MAX_AGE);
        assertEq(uint256(atOpen), uint256(PushFeedGuard.Verdict.ALLOW), "the open second is inside");
        vm.warp(s.closeUtc);
        (PushFeedGuard.Verdict atClose, PushFeedGuard.Reason why,,) = guard.check(address(feed), MAX_AGE);
        assertEq(uint256(atClose), uint256(PushFeedGuard.Verdict.REJECT), "the close second is outside");
        assertEq(uint256(why), uint256(PushFeedGuard.Reason.OUTSIDE_SESSION));
    }
}
