// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SessionCalendar
/// @notice Pure, dependency-free calendar of US equities regular sessions (NYSE/Nasdaq),
///         expressed in UTC. Used by Bell to decide the boundaries O (open) and C (close)
///         of the regular session for any block timestamp.
///
/// Design notes
/// - The calendar only bounds admissibility. It never asserts that the market IS open:
///   that comes from the DON-signed marketStatus in each Data Streams report.
/// - DST follows the US rule in force since 2007: starts 2nd Sunday of March 02:00 local,
///   ends 1st Sunday of November 02:00 local. Computed, not tabulated, so it holds for
///   every year until the law changes (calendarVersion bumps if it does).
/// - Holidays and early closes are tabulated per year from the NYSE Group calendar
///   (2026-2028 announced 2025-12-23). Only years present in the table are supported;
///   any other year reports NO_SESSION for every day (fail closed, never fail open).
/// - Regular session: 09:30-16:00 ET; early-close days: 09:30-13:00 ET.
library SessionCalendar {
    uint32 public constant CALENDAR_VERSION = 1;

    uint64 internal constant DAY = 86400;
    uint64 internal constant HOUR = 3600;
    uint64 internal constant EST_OFFSET = 5 * HOUR; // UTC-5
    uint64 internal constant EDT_OFFSET = 4 * HOUR; // UTC-4
    uint64 internal constant OPEN_LOCAL = 9 * HOUR + 30 * 60; // 09:30 ET
    uint64 internal constant CLOSE_LOCAL = 16 * HOUR; // 16:00 ET
    uint64 internal constant EARLY_CLOSE_LOCAL = 13 * HOUR; // 13:00 ET

    struct Session {
        bool exists; // false on weekends, holidays and unsupported years
        bool earlyClose;
        uint32 tradingDate; // YYYYMMDD in ET
        uint64 openUtc; // O
        uint64 closeUtc; // C (exclusive bound of the regular interval [O, C))
    }

    // ---------------------------------------------------------------------
    // Public API
    // ---------------------------------------------------------------------

    /// @notice Session of the ET trading day that contains `ts` (UTC seconds).
    function sessionAt(uint64 ts) internal pure returns (Session memory s) {
        uint64 local = ts - _offsetAt(ts);
        int256 days_ = int256(uint256(local / DAY));
        (int256 y, uint256 m, uint256 d) = _civilFromDays(days_);
        return sessionForDate(uint32(uint256(y)) * 10000 + uint32(m) * 100 + uint32(d));
    }

    /// @notice Session for an ET trading date given as YYYYMMDD.
    function sessionForDate(uint32 ymd) internal pure returns (Session memory s) {
        s.tradingDate = ymd;
        (uint256 y, uint256 m, uint256 d) = (ymd / 10000, (ymd / 100) % 100, ymd % 100);
        if (!_yearSupported(y)) return s;
        int256 days_ = _daysFromCivil(int256(y), m, d);
        uint256 dow = uint256((days_ + 4) % 7); // 0 = Sunday ... 6 = Saturday
        if (dow == 0 || dow == 6) return s;
        if (_isHoliday(ymd)) return s;
        uint64 offset = _isDstDate(y, m, d) ? EDT_OFFSET : EST_OFFSET;
        uint64 dayStart = uint64(uint256(days_)) * DAY;
        s.exists = true;
        s.earlyClose = _isEarlyClose(ymd);
        s.openUtc = dayStart + OPEN_LOCAL + offset;
        s.closeUtc = dayStart + (s.earlyClose ? EARLY_CLOSE_LOCAL : CLOSE_LOCAL) + offset;
    }

    /// @notice ET offset (seconds behind UTC) in force at UTC timestamp `ts`.
    function offsetAt(uint64 ts) internal pure returns (uint64) {
        return _offsetAt(ts);
    }

    // ---------------------------------------------------------------------
    // Tables (NYSE Group holiday & early-close calendar, 2026-2027)
    // ---------------------------------------------------------------------

    function _yearSupported(uint256 y) private pure returns (bool) {
        return y == 2026 || y == 2027;
    }

    function _isHoliday(uint32 ymd) private pure returns (bool) {
        // 2026: New Year, MLK, Presidents, Good Friday, Memorial, Juneteenth,
        //       Independence (observed Fri Jul 3), Labor, Thanksgiving, Christmas.
        if (
            ymd == 20260101 || ymd == 20260119 || ymd == 20260216 || ymd == 20260403 || ymd == 20260525
                || ymd == 20260619 || ymd == 20260703 || ymd == 20260907 || ymd == 20261126 || ymd == 20261225
        ) return true;
        // 2027: New Year, MLK, Presidents, Good Friday, Memorial, Juneteenth (observed Fri Jun 18),
        //       Independence (observed Mon Jul 5), Labor, Thanksgiving, Christmas (observed Fri Dec 24).
        if (
            ymd == 20270101 || ymd == 20270118 || ymd == 20270215 || ymd == 20270326 || ymd == 20270531
                || ymd == 20270618 || ymd == 20270705 || ymd == 20270906 || ymd == 20271125 || ymd == 20271224
        ) return true;
        return false;
    }

    function _isEarlyClose(uint32 ymd) private pure returns (bool) {
        // 2026: day after Thanksgiving, Christmas Eve. 2027: day after Thanksgiving.
        return ymd == 20261127 || ymd == 20261224 || ymd == 20271126;
    }

    // ---------------------------------------------------------------------
    // DST (US rule since 2007)
    // ---------------------------------------------------------------------

    /// @dev DST is in force on an ET date iff date >= 2nd Sunday of March and < 1st Sunday of November.
    function _isDstDate(uint256 y, uint256 m, uint256 d) private pure returns (bool) {
        if (m < 3 || m > 11) return false;
        if (m > 3 && m < 11) return true;
        if (m == 3) return d >= _nthSunday(y, 3, 2);
        return d < _nthSunday(y, 11, 1); // m == 11
    }

    /// @dev Offset at a UTC instant. Transitions happen at 07:00 UTC (spring) and 06:00 UTC (fall).
    function _offsetAt(uint64 ts) private pure returns (uint64) {
        (int256 y,,) = _civilFromDays(int256(uint256(ts / DAY)));
        uint256 yy = uint256(y);
        uint64 dstStart = uint64(uint256(_daysFromCivil(y, 3, _nthSunday(yy, 3, 2)))) * DAY + 7 * HOUR;
        uint64 dstEnd = uint64(uint256(_daysFromCivil(y, 11, _nthSunday(yy, 11, 1)))) * DAY + 6 * HOUR;
        return (ts >= dstStart && ts < dstEnd) ? EDT_OFFSET : EST_OFFSET;
    }

    /// @dev Day of month of the n-th Sunday of (y, m).
    function _nthSunday(uint256 y, uint256 m, uint256 n) private pure returns (uint256) {
        int256 first = _daysFromCivil(int256(y), m, 1);
        uint256 dowFirst = uint256((first + 4) % 7); // 0 = Sunday
        uint256 firstSunday = 1 + (7 - dowFirst) % 7;
        return firstSunday + 7 * (n - 1);
    }

    // ---------------------------------------------------------------------
    // Civil date arithmetic (Howard Hinnant's algorithms, proleptic Gregorian)
    // ---------------------------------------------------------------------

    function _daysFromCivil(int256 y, uint256 m, uint256 d) private pure returns (int256) {
        if (m <= 2) y -= 1;
        int256 era = (y >= 0 ? y : y - 399) / 400;
        uint256 yoe = uint256(y - era * 400);
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + int256(doe) - 719468;
    }

    function _civilFromDays(int256 z) private pure returns (int256 y, uint256 m, uint256 d) {
        z += 719468;
        int256 era = (z >= 0 ? z : z - 146096) / 146097;
        uint256 doe = uint256(z - era * 146097);
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = int256(yoe) + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
}
