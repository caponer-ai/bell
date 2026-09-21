// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PushFeedGuard} from "../src/PushFeedGuard.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";
import {Aggregator} from "./SettleOnMark.t.sol";

/// What it costs to ask the session question, measured rather than promised.
///
/// Anyone deciding whether to put a third-party call in their settlement path asks this first, and until
/// now this repo had no answer. The thresholds below are the measured numbers plus roughly twenty percent,
/// not round figures chosen because they looked sensible: the first version of this file asserted limits
/// invented from memory and every one of them failed. `forge test --match-path "test/Gas.t.sol" --gas-report` prints the table;
/// these tests assert the numbers stay where they are, so a refactor that quietly triples the cost fails
/// instead of shipping.
///
/// Day used: 2026-09-22 (Tuesday, EDT), O = 13:30:00 UTC, C = 20:00:00 UTC.
contract GasTest is Test {
    PushFeedGuard guard;
    Aggregator feed;

    uint64 constant O = 1790083800;

    function setUp() public {
        guard = new PushFeedGuard();
        feed = new Aggregator(33500000000, O + 60);
        vm.warp(O + 300);
    }

    function test_check_inside_the_session() public {
        uint256 before = gasleft();
        guard.check(address(feed), 900);
        uint256 used = before - gasleft();
        emit log_named_uint("check() inside the session", used);
        assertLt(used, 33_000, "measured 27,311 on 2026-09-21; this catches a regression, not a target");
    }

    function test_check_outside_the_session_is_cheaper() public {
        vm.warp(O - 3600);
        uint256 before = gasleft();
        guard.check(address(feed), 900);
        uint256 used = before - gasleft();
        emit log_named_uint("check() before the bell", used);
        // Outside the session the guard answers from the calendar alone and never reads the feed.
        assertLt(used, 19_000, "measured 15,926: refusing early is cheaper because the feed is never read");
    }

    function test_calendar_alone() public {
        uint256 before = gasleft();
        SessionCalendar.sessionAt(uint64(block.timestamp));
        uint256 used = before - gasleft();
        emit log_named_uint("sessionAt() pure calendar", used);
        assertLt(used, 14_000, "measured 11,151 for the pure calendar");
    }

    function test_thirty_five_feeds_in_one_call() public {
        address[] memory feeds = new address[](35);
        for (uint256 i = 0; i < 35; i++) {
            feeds[i] = address(new Aggregator(33500000000 + int256(i), O + 60));
        }
        uint256 before = gasleft();
        guard.checkMany(feeds, 900);
        uint256 used = before - gasleft();
        emit log_named_uint("checkMany() 35 feeds", used);
        emit log_named_uint("per feed", used / 35);
        assertLt(used / 35, 26_000, "measured 21,447 per feed, against 27,311 for a single in-session check");
    }
}
