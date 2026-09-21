// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";

/// Every day of 2026 and 2027, checked against the official NYSE schedule.
///
/// Source: NYSE Group's own announcement of the 2026, 2027 and 2028 holiday and early closings calendar
/// (ir.theice.com, read 2026-09-21). Both lists are transcribed below so a reviewer can compare them with
/// the press release line by line, instead of trusting that the tabulation inside SessionCalendar is right.
///
/// A calendar bug is the quiet kind: it does not revert, it simply calls a closed day open, or an early
/// close a full session, on exactly the day when settlements are most sensitive. 730 assertions are
/// cheaper than one of those.
contract SessionCalendarScheduleTest is Test {
    uint32[10] private HOLIDAYS_2026 = [
        uint32(20260101), // Thursday, New Year's Day
        20260119, // Monday, Martin Luther King, Jr. Day
        20260216, // Monday, Washington's Birthday
        20260403, // Friday, Good Friday
        20260525, // Monday, Memorial Day
        20260619, // Friday, Juneteenth
        20260703, // Friday, Independence Day observed
        20260907, // Monday, Labor Day
        20261126, // Thursday, Thanksgiving
        20261225 // Friday, Christmas Day
    ];

    uint32[10] private HOLIDAYS_2027 = [
        uint32(20270101), // Friday, New Year's Day
        20270118, // Monday, Martin Luther King, Jr. Day
        20270215, // Monday, Washington's Birthday
        20270326, // Friday, Good Friday
        20270531, // Monday, Memorial Day
        20270618, // Friday, Juneteenth observed
        20270705, // Monday, Independence Day observed
        20270906, // Monday, Labor Day
        20271125, // Thursday, Thanksgiving
        20271224 // Friday, Christmas Day observed
    ];

    uint32[2] private EARLY_2026 = [uint32(20261127), 20261224]; // day after Thanksgiving, Christmas Eve
    uint32[1] private EARLY_2027 = [uint32(20271126)]; // day after Thanksgiving

    uint256 private constant DAY = 86400;

    function _isIn(uint32 date, uint32[10] storage list) private view returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == date) return true;
        }
        return false;
    }

    function _isEarly(uint32 date) private view returns (bool) {
        for (uint256 i = 0; i < EARLY_2026.length; i++) {
            if (EARLY_2026[i] == date) return true;
        }
        for (uint256 i = 0; i < EARLY_2027.length; i++) {
            if (EARLY_2027[i] == date) return true;
        }
        return false;
    }

    /// 2026-01-01 as days since the epoch, so the walk needs no civil-date conversion at all.
    uint256 private constant DAY_2026_01_01 = 20454;

    function _weekday(uint256 daysSinceEpoch) private pure returns (uint256) {
        return (daysSinceEpoch + 4) % 7; // 0 = Sunday
    }

    function _monthLength(uint256 y, uint256 m) private pure returns (uint256) {
        if (m == 2) return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28;
        if (m == 4 || m == 6 || m == 9 || m == 11) return 30;
        return 31;
    }

    /// Walks a year day by day from a known epoch index, comparing the contract with the official list.
    /// `firstDay` is the epoch day index of 1 January of that year; DST is derived from the weekday walk,
    /// not from a second implementation of the civil calendar.
    function _checkYear(uint256 year, uint256 firstDay, uint32[10] storage holidays) private view {
        uint256 sessions;
        uint256 day = firstDay;

        // DST runs from the second Sunday of March to the first Sunday of November (US rule)
        uint256 marchSundays;
        uint256 dstStart;
        uint256 dstEnd;
        for (uint256 d = 1; d <= 31; d++) {
            uint256 idx = day + _offsetInYear(year, 3, d);
            if (_weekday(idx) == 0) {
                marchSundays++;
                if (marchSundays == 2) dstStart = idx;
            }
        }
        for (uint256 d = 1; d <= 30; d++) {
            uint256 idx = day + _offsetInYear(year, 11, d);
            if (_weekday(idx) == 0) {
                dstEnd = idx;
                break;
            }
        }
        assertTrue(dstStart > 0 && dstEnd > dstStart, "DST boundaries found");

        for (uint256 m = 1; m <= 12; m++) {
            for (uint256 d = 1; d <= _monthLength(year, m); d++) {
                uint256 idx = day + _offsetInYear(year, m, d);
                uint32 date = uint32(year * 10000 + m * 100 + d);
                SessionCalendar.Session memory s = SessionCalendar.sessionForDate(date);

                uint256 wd = _weekday(idx);
                bool shouldExist = wd != 0 && wd != 6 && !_isIn(date, holidays);
                assertEq(s.exists, shouldExist, string.concat("session existence wrong on ", vm.toString(date)));
                if (!shouldExist) continue;
                sessions++;

                bool dst = idx >= dstStart && idx < dstEnd;
                uint256 midnight = idx * DAY;
                uint256 expectedOpen = midnight + (dst ? uint256(13) : 14) * 3600 + 1800;
                uint256 closeHour = _isEarly(date) ? (dst ? uint256(17) : 18) : (dst ? uint256(20) : 21);
                uint256 expectedClose = midnight + closeHour * 3600;

                assertEq(s.tradingDate, date, "trading date");
                assertEq(uint256(s.openUtc), expectedOpen, string.concat("open wrong on ", vm.toString(date)));
                assertEq(uint256(s.closeUtc), expectedClose, string.concat("close wrong on ", vm.toString(date)));
                assertEq(s.earlyClose, _isEarly(date), string.concat("early close flag wrong on ", vm.toString(date)));
            }
        }
        assertEq(sessions, 251, "number of trading days in the year");
    }

    /// Days elapsed from 1 January of `year` to (m, d) of the same year.
    function _offsetInYear(uint256 year, uint256 m, uint256 d) private pure returns (uint256 offset) {
        for (uint256 i = 1; i < m; i++) {
            offset += _monthLength(year, i);
        }
        offset += d - 1;
    }

    function test_every_day_of_2026_matches_the_official_nyse_schedule() public view {
        _checkYear(2026, DAY_2026_01_01, HOLIDAYS_2026);
    }

    function test_every_day_of_2027_matches_the_official_nyse_schedule() public view {
        _checkYear(2027, DAY_2026_01_01 + 365, HOLIDAYS_2027);
    }

    /// The two DST boundaries: the session shifts by an hour in UTC and the contract must shift with it.
    function test_dst_boundaries_move_the_session_by_one_hour() public pure {
        // 2026-03-06 is EST, 2026-03-09 is EDT (DST starts Sunday 2026-03-08)
        SessionCalendar.Session memory before = SessionCalendar.sessionForDate(20260306);
        SessionCalendar.Session memory afterStart = SessionCalendar.sessionForDate(20260309);
        assertEq(uint256(before.openUtc) % DAY, 14 * 3600 + 1800, "EST open is 14:30 UTC");
        assertEq(uint256(afterStart.openUtc) % DAY, 13 * 3600 + 1800, "EDT open is 13:30 UTC");

        // 2026-10-30 is EDT, 2026-11-02 is EST (DST ends Sunday 2026-11-01)
        SessionCalendar.Session memory beforeEnd = SessionCalendar.sessionForDate(20261030);
        SessionCalendar.Session memory afterEnd = SessionCalendar.sessionForDate(20261102);
        assertEq(uint256(beforeEnd.openUtc) % DAY, 13 * 3600 + 1800, "still EDT");
        assertEq(uint256(afterEnd.openUtc) % DAY, 14 * 3600 + 1800, "back to EST");
    }

    /// Both early closes of 2026 are three and a half hours shorter than a normal session.
    function test_early_closes_are_exactly_three_and_a_half_hours_short() public view {
        for (uint256 i = 0; i < EARLY_2026.length; i++) {
            SessionCalendar.Session memory s = SessionCalendar.sessionForDate(EARLY_2026[i]);
            assertTrue(s.exists && s.earlyClose, "early close day must still be a session");
            assertEq(s.closeUtc - s.openUtc, 3 hours + 30 minutes, "13:00 ET close");
        }
        SessionCalendar.Session memory normal = SessionCalendar.sessionForDate(20261123);
        assertEq(normal.closeUtc - normal.openUtc, 6 hours + 30 minutes, "a normal session");
    }

    /// Outside the tabulated years the calendar fails closed rather than guessing.
    function test_unsupported_years_have_no_sessions() public pure {
        assertFalse(SessionCalendar.sessionForDate(20250602).exists, "2025 is not tabulated");
        assertFalse(SessionCalendar.sessionForDate(20280602).exists, "2028 is not tabulated");
    }
}
