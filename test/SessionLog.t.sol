// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PushFeedGuard} from "../src/PushFeedGuard.sol";
import {SessionLog} from "../src/SessionLog.sol";

contract Aggregator {
    uint8 public constant decimals = 8;
    int256 public answer;
    uint256 public updatedAt;

    constructor(int256 a, uint256 u) {
        answer = a;
        updatedAt = u;
    }

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// Day 2026-09-22 (Tuesday, EDT): O = 13:30:00 UTC, C = 20:00:00 UTC.
contract SessionLogTest is Test {
    PushFeedGuard guard;
    SessionLog sessionLog;
    Aggregator feed;

    uint64 constant O = 1790083800;
    uint64 constant C = 1790107200;
    uint32 constant DAY = 20260922;
    int256 constant PRICE = 33553000000; // 335.53

    function setUp() public {
        guard = new PushFeedGuard();
        sessionLog = new SessionLog(guard);
        feed = new Aggregator(PRICE, O - 7 hours); // yesterday's close, as the feeds actually look
    }

    // ------------------------------------------------------------------
    // The mark at the bell
    // ------------------------------------------------------------------
    function test_open_mark_records_what_a_contract_would_have_seen() public {
        vm.warp(O + 1);
        sessionLog.mark(address(feed), SessionLog.Kind.OPEN);

        SessionLog.Mark memory m = sessionLog.getMark(address(feed), DAY, SessionLog.Kind.OPEN);
        assertTrue(m.set);
        assertEq(m.tradingDate, DAY);
        assertEq(m.markedAt, O + 1);
        assertEq(m.answer, int192(PRICE));
        assertEq(m.updatedAt, O - 7 hours, "the price at the bell is seven hours old");
        assertEq(m.verdict, uint8(PushFeedGuard.Verdict.ALLOW), "no staleness budget applies to a record");
        assertEq(sessionLog.totalMarks(), 1);
    }

    function test_open_mark_is_refused_before_the_bell_and_after_the_window() public {
        vm.warp(O - 1);
        vm.expectRevert(SessionLog.OutsideMarkWindow.selector);
        sessionLog.mark(address(feed), SessionLog.Kind.OPEN);

        vm.warp(O + sessionLog.WINDOW());
        vm.expectRevert(SessionLog.OutsideMarkWindow.selector);
        sessionLog.mark(address(feed), SessionLog.Kind.OPEN);
    }

    function test_close_mark_window_ends_at_the_closing_bell() public {
        vm.warp(C - 1);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);
        assertTrue(sessionLog.getMark(address(feed), DAY, SessionLog.Kind.CLOSE).set);

        vm.warp(C);
        vm.expectRevert(SessionLog.OutsideMarkWindow.selector);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);
    }

    function test_first_writer_wins_and_nothing_can_be_rewritten() public {
        vm.warp(O + 1);
        sessionLog.mark(address(feed), SessionLog.Kind.OPEN);
        feed.set(PRICE * 2, O + 2);
        vm.warp(O + 3);
        vm.expectRevert(SessionLog.AlreadyMarked.selector);
        sessionLog.mark(address(feed), SessionLog.Kind.OPEN);
        assertEq(sessionLog.getMark(address(feed), DAY, SessionLog.Kind.OPEN).answer, int192(PRICE), "unchanged");
    }

    function test_no_session_means_no_mark() public {
        vm.warp(1790434800); // Saturday
        vm.expectRevert(SessionLog.NoSession.selector);
        sessionLog.mark(address(feed), SessionLog.Kind.OPEN);
    }

    function test_an_address_with_no_code_is_refused() public {
        vm.warp(O + 1);
        vm.expectRevert(SessionLog.NoFeed.selector);
        sessionLog.mark(address(0xdead), SessionLog.Kind.OPEN);
    }

    // ------------------------------------------------------------------
    // The first print of the session, measured against the bell
    // ------------------------------------------------------------------
    function test_first_print_cannot_be_recorded_before_the_feed_prints() public {
        vm.warp(O + 60);
        vm.expectRevert(SessionLog.NotYetPrinted.selector);
        sessionLog.markFirstPrint(address(feed));
    }

    function test_first_print_records_the_delay_from_the_bell() public {
        feed.set(PRICE, O + 317); // the feed's first regular-session update
        vm.warp(O + 320);
        uint64 delay = sessionLog.markFirstPrint(address(feed));
        assertEq(delay, 317, "measured against the opening bell, not against the caller");

        SessionLog.FirstPrint memory fp = sessionLog.getFirstPrint(address(feed), DAY);
        assertTrue(fp.set);
        assertEq(fp.updatedAt, O + 317);
        assertEq(fp.observedAt, O + 320);
        assertEq(sessionLog.totalFirstPrints(), 1);
    }

    function test_first_print_is_recorded_once_per_day() public {
        feed.set(PRICE, O + 100);
        vm.warp(O + 120);
        sessionLog.markFirstPrint(address(feed));
        feed.set(PRICE, O + 200);
        vm.warp(O + 220);
        vm.expectRevert(SessionLog.AlreadyMarked.selector);
        sessionLog.markFirstPrint(address(feed));
    }

    function test_first_print_is_refused_outside_the_session() public {
        feed.set(PRICE, O + 100);
        vm.warp(C + 1);
        vm.expectRevert(SessionLog.OutsideMarkWindow.selector);
        sessionLog.markFirstPrint(address(feed));
    }

    /// The delay stored is an upper bound: nobody can make it look smaller than the print itself.
    function test_a_late_caller_cannot_understate_the_delay() public {
        feed.set(PRICE, O + 1000);
        vm.warp(O + 5000); // somebody remembers to call four thousand seconds later
        uint64 delay = sessionLog.markFirstPrint(address(feed));
        assertEq(delay, 1000, "the feed's own timestamp decides, not the caller's");
    }

    // ------------------------------------------------------------------
    // Batch views, which is how a dashboard or an auditor reads it
    // ------------------------------------------------------------------
    function test_batch_views_return_one_entry_per_feed() public {
        Aggregator second = new Aggregator(PRICE, O - 1 hours);
        address[] memory feeds = new address[](2);
        feeds[0] = address(feed);
        feeds[1] = address(second);

        vm.warp(O + 2);
        sessionLog.mark(feeds[0], SessionLog.Kind.OPEN);
        sessionLog.mark(feeds[1], SessionLog.Kind.OPEN);

        SessionLog.Mark[] memory marks = sessionLog.getMarks(feeds, DAY, SessionLog.Kind.OPEN);
        assertEq(marks.length, 2);
        assertTrue(marks[0].set && marks[1].set);
        assertEq(marks[1].updatedAt, O - 1 hours);

        SessionLog.FirstPrint[] memory prints = sessionLog.getFirstPrints(feeds, DAY);
        assertFalse(prints[0].set, "nothing printed yet today");
    }
}
