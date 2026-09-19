// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";

contract SessionCalendarHarness {
    function sessionForDate(uint32 ymd) external pure returns (SessionCalendar.Session memory) {
        return SessionCalendar.sessionForDate(ymd);
    }

    function sessionAt(uint64 ts) external pure returns (SessionCalendar.Session memory) {
        return SessionCalendar.sessionAt(ts);
    }

    function offsetAt(uint64 ts) external pure returns (uint64) {
        return SessionCalendar.offsetAt(ts);
    }
}

/// Dates and expectations come from the Bell v0.1 spec (NYSE Group calendar 2026-2028, US DST rule).
contract SessionCalendarTest is Test {
    SessionCalendarHarness cal;

    function setUp() public {
        cal = new SessionCalendarHarness();
    }

    function _utc(uint256 y, uint256 m, uint256 d, uint256 hh, uint256 mm) internal pure returns (uint64) {
        // days from civil, inlined for the test (same algorithm as the library)
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        uint256 days_ = era * 146097 + doe - 719468;
        return uint64(days_ * 86400 + hh * 3600 + mm * 60);
    }

    function test_estRegularDay_2026_03_06() public view {
        SessionCalendar.Session memory s = cal.sessionForDate(20260306);
        assertTrue(s.exists);
        assertFalse(s.earlyClose);
        assertEq(s.openUtc, _utc(2026, 3, 6, 14, 30), "open 14:30 UTC (EST)");
        assertEq(s.closeUtc, _utc(2026, 3, 6, 21, 0), "close 21:00 UTC (EST)");
    }

    function test_edtFirstTradingDay_2026_03_09() public view {
        SessionCalendar.Session memory s = cal.sessionForDate(20260309);
        assertTrue(s.exists);
        assertEq(s.openUtc, _utc(2026, 3, 9, 13, 30), "open 13:30 UTC (EDT)");
        assertEq(s.closeUtc, _utc(2026, 3, 9, 20, 0), "close 20:00 UTC (EDT)");
    }

    function test_edtLastTradingDay_2026_10_30() public view {
        SessionCalendar.Session memory s = cal.sessionForDate(20261030);
        assertEq(s.openUtc, _utc(2026, 10, 30, 13, 30), "open 13:30 UTC (EDT)");
    }

    function test_estAfterFallBack_2026_11_02() public view {
        SessionCalendar.Session memory s = cal.sessionForDate(20261102);
        assertEq(s.openUtc, _utc(2026, 11, 2, 14, 30), "open 14:30 UTC (EST)");
    }

    function test_earlyClose_2026_11_27() public view {
        SessionCalendar.Session memory s = cal.sessionForDate(20261127);
        assertTrue(s.exists);
        assertTrue(s.earlyClose);
        assertEq(s.openUtc, _utc(2026, 11, 27, 14, 30));
        assertEq(s.closeUtc, _utc(2026, 11, 27, 18, 0), "close 18:00 UTC (13:00 EST)");
    }

    function test_earlyClose_2026_12_24() public view {
        SessionCalendar.Session memory s = cal.sessionForDate(20261224);
        assertTrue(s.earlyClose);
        assertEq(s.closeUtc, _utc(2026, 12, 24, 18, 0));
    }

    function test_holiday_2026_07_03_noSession() public view {
        // Independence Day observed: NYSE fully closed (Chainlink market-hours docs wrongly list an early close).
        assertFalse(cal.sessionForDate(20260703).exists);
    }

    function test_laborDay_2026_09_07_noSession() public view {
        assertFalse(cal.sessionForDate(20260907).exists);
    }

    function test_weekend_noSession() public view {
        assertFalse(cal.sessionForDate(20260912).exists, "Saturday");
        assertFalse(cal.sessionForDate(20260913).exists, "Sunday");
    }

    function test_unsupportedYear_failsClosed() public view {
        assertFalse(cal.sessionForDate(20280105).exists);
        assertFalse(cal.sessionForDate(20250905).exists);
    }

    function test_sessionAt_mapsUtcToEtTradingDate() public view {
        // 2026-09-09 01:30 UTC is still 2026-09-08 21:30 ET -> trading date 20260908.
        SessionCalendar.Session memory s = cal.sessionAt(_utc(2026, 9, 9, 1, 30));
        assertEq(s.tradingDate, 20260908);
        // 2026-09-09 13:30:00 UTC is exactly the open of 20260909.
        s = cal.sessionAt(_utc(2026, 9, 9, 13, 30));
        assertEq(s.tradingDate, 20260909);
        assertEq(s.openUtc, _utc(2026, 9, 9, 13, 30));
        assertEq(s.closeUtc, _utc(2026, 9, 9, 20, 0));
    }

    function test_offsetAt_transitions() public view {
        // Spring forward 2026-03-08 07:00 UTC; fall back 2026-11-01 06:00 UTC.
        assertEq(cal.offsetAt(_utc(2026, 3, 8, 6, 59)), 5 * 3600);
        assertEq(cal.offsetAt(_utc(2026, 3, 8, 7, 0)), 4 * 3600);
        assertEq(cal.offsetAt(_utc(2026, 11, 1, 5, 59)), 4 * 3600);
        assertEq(cal.offsetAt(_utc(2026, 11, 1, 6, 0)), 5 * 3600);
    }

    /// Real fixture: AAPL report observed 1788883200 = 2026-09-08 16:00:00 UTC (12:00 ET) lies inside [O, C) of 20260908.
    function test_fixtureObservationInsideSession() public view {
        SessionCalendar.Session memory s = cal.sessionAt(1788883200);
        assertTrue(s.exists);
        assertEq(s.tradingDate, 20260908);
        assertTrue(1788883200 >= s.openUtc && 1788883200 < s.closeUtc);
    }
}
