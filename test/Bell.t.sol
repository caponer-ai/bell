// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

/// Unit tests of Bell against a mock proxy (no signatures). Numbered after docs/SPEC-v0.1.md §"Tests".
/// Trading day used throughout: 2026-09-09 (EDT): O = 13:30:00 UTC, C = 20:00:00 UTC.
/// Policy v2 (ladder): OPEN rung i target = O + 30 i, CLOSE rung i target = C - 1 - 30 i, i < 8.
contract BellTest is Test {
    MockVerifierProxy proxy;
    Bell bell;

    bytes32 constant FEED = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant DIGEST = 0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee;
    uint32 constant DAY = 20260909;
    uint64 constant O = 1788960600; // 2026-09-09 13:30:00 UTC
    uint64 constant C = 1788984000; // 2026-09-09 20:00:00 UTC
    uint64 constant N = 300;
    uint64 constant R = 30;
    uint64 constant NS = 1e9;

    function setUp() public {
        proxy = new MockVerifierProxy();
        proxy.setVerifier(DIGEST, address(0xBEEF));
        bell = new Bell(IVerifierProxy(address(proxy)), new bytes32[](0), new address[](0));
        SessionCalendar.Session memory s = SessionCalendar.sessionForDate(DAY);
        assertEq(s.openUtc, O, "O");
        assertEq(s.closeUtc, C, "C");
        assertEq(bell.rungTarget(DAY, false, 0), O, "open rung 0");
        assertEq(bell.rungTarget(DAY, false, 7), O + 7 * R, "open rung 7");
        assertEq(bell.rungTarget(DAY, true, 0), C - 1, "close rung 0");
        assertEq(bell.rungTarget(DAY, true, 8), 0, "no rung 8");
    }

    // ------------------------------------------------------------------
    // Payload builder: abi.encode(bytes32[3] ctx, bytes reportData, bytes32[] rs, bytes32[] ss, bytes32 rawVs)
    // ------------------------------------------------------------------
    struct P {
        uint32 obs;
        int192 mid;
        uint64 lastSeenNs;
        uint32 status;
        uint32 expiresAt;
        uint32 validFrom;
        bytes32 feedId;
        bytes32 salt; // makes payload hash unique when needed
    }

    /// Report observed at `obs` with the mid last seen in that same second (as in the 38 mainnet fixtures:
    /// validFrom == obs in 34 of them, obs == validFrom + 1 in 4).
    function _p(uint64 obs, int192 mid, uint32 status) internal pure returns (P memory p) {
        p.obs = uint32(obs);
        p.mid = mid;
        p.lastSeenNs = obs * NS;
        p.status = status;
        p.expiresAt = uint32(obs + 30 days);
        p.validFrom = uint32(obs);
        p.feedId = FEED;
    }

    function _payload(P memory p) internal pure returns (bytes memory) {
        bytes memory reportData = abi.encode(
            p.feedId,
            p.validFrom,
            p.obs,
            uint192(0),
            uint192(0),
            p.expiresAt,
            p.mid,
            p.lastSeenNs,
            p.mid - 1e16,
            int192(100e18),
            p.mid + 1e16,
            int192(100e18),
            p.mid,
            p.status
        );
        bytes32[3] memory ctx = [DIGEST, bytes32(uint256(1)), p.salt];
        bytes32[] memory rs = new bytes32[](1);
        bytes32[] memory ss = new bytes32[](1);
        return abi.encode(ctx, reportData, rs, ss, bytes32(0));
    }

    function _post(P memory p, uint64 at) internal returns (bytes32) {
        vm.warp(at);
        return bell.post(_payload(p));
    }

    // ------------------------------------------------------------------
    // 1. replay_same_report
    // ------------------------------------------------------------------
    function test_01_replay_same_report_no_state_change() public {
        P memory p = _p(O, 316e18, 2);
        bytes32 r1 = _post(p, O + 5);
        Bell.Candidate memory c1 = bell.openReference(FEED, DAY);
        bytes32 r2 = _post(p, O + 40);
        Bell.Candidate memory c2 = bell.openReference(FEED, DAY);
        assertEq(r1, r2, "same receipt");
        assertEq(c1.receiptId, c2.receiptId);
        assertEq(c1.observationsTimestamp, c2.observationsTimestamp);
        assertEq(bell.receipt(r1).acceptedAt, O + 5, "first acceptance time kept");
        assertEq(bell.receipt(r1).phase, 1, "evidence for the OPEN fixing");
    }

    // ------------------------------------------------------------------
    // 2. expired_expiresAt
    // ------------------------------------------------------------------
    function test_02_expired_report_reverts() public {
        P memory p = _p(O, 316e18, 2);
        p.expiresAt = uint32(O + 100);
        vm.warp(O + 101);
        vm.expectRevert(Bell.Expired.selector);
        bell.post(_payload(p));
    }

    // ------------------------------------------------------------------
    // 3. status2_obs_before_boundary
    // ------------------------------------------------------------------
    function test_03_status2_before_boundary_not_a_candidate() public {
        P memory p = _p(O - 120, 316e18, 2); // 13:28 UTC, DON already says regular
        _post(p, O + 1);
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertFalse(c.set, "pre-boundary observation covers no rung");
        vm.warp(O + N);
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_UNRESOLVED));
        (Bell.Verdict v, Bell.Reason why,,) = bell.checkSettle(FEED, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.REJECT));
        assertEq(uint256(why), uint256(Bell.Reason.REFERENCE_UNRESOLVED));
    }

    // ------------------------------------------------------------------
    // 4. poster_late_11min_plus_backfill (deadline anchored to the boundary, not to the first post)
    // ------------------------------------------------------------------
    function test_04_late_poster_window_anchored_to_boundary() public {
        P memory late = _p(O, 316e18, 2);
        vm.warp(O + 11 minutes);
        bell.post(_payload(late)); // accepted as a report, but too late to be evidence
        assertFalse(bell.openReference(FEED, DAY).set, "late post cannot open the window");
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    function test_04b_backfill_lower_rung_within_window_wins() public {
        P memory first = _p(O + R, 316e18, 2); // rung 1
        _post(first, O + R + 1);
        assertEq(bell.openReference(FEED, DAY).rung, 1);
        P memory earlier = _p(O, 315e18, 2); // rung 0, mid seen exactly at the bell: eligible (l >= O). A mid
        // last seen before O (e.g. O - 0.5 s) is a pre-open quote and proves rung 0 out instead.
        _post(earlier, O + 90);
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertEq(c.observationsTimestamp, uint32(O), "lower rung wins regardless of order");
        assertEq(c.rung, 0);
        assertEq(c.mid, 315e18);
        vm.warp(O + N);
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_FINAL));
    }

    // ------------------------------------------------------------------
    // 5. duplicate_same_second: same rung, different mid -> CONFLICT -> UNRESOLVED
    // ------------------------------------------------------------------
    function test_05_same_rung_different_mid_is_conflict() public {
        P memory a = _p(O, 316e18, 2);
        P memory b = _p(O, 317e18, 2);
        _post(a, O + 2);
        _post(b, O + 3);
        assertTrue(bell.openReference(FEED, DAY).conflict);
        vm.warp(O + N);
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    function test_05b_exact_duplicate_is_not_conflict() public {
        P memory a = _p(O, 316e18, 2);
        P memory a2 = _p(O, 316e18, 2);
        a2.salt = bytes32(uint256(7)); // different payload bytes, identical report content
        _post(a, O + 2);
        _post(a2, O + 3);
        assertFalse(bell.openReference(FEED, DAY).conflict);
    }

    // ------------------------------------------------------------------
    // 6. status0_unknown: proves the rung out, never a candidate, LIVE says WAIT
    // ------------------------------------------------------------------
    function test_06_status_unknown_does_not_open() public {
        _post(_p(O, 316e18, 0), O + 2);
        assertFalse(bell.openReference(FEED, DAY).set);
        assertEq(bell.provenRungs(FEED, DAY, false), 1, "rung 0 proven out");
        (Bell.Verdict v, Bell.Reason why) = bell.checkLive(FEED);
        assertEq(uint256(v), uint256(Bell.Verdict.WAIT));
        assertEq(uint256(why), uint256(Bell.Reason.STATUS_UNKNOWN));
    }

    // ------------------------------------------------------------------
    // 7. halt_via_lastSeenNs: status 2 but mid not seen for > 60 s -> not eligible, LIVE MID_STALE
    // ------------------------------------------------------------------
    function test_07_halt_detected_via_lastSeen() public {
        P memory p = _p(O, 316e18, 2);
        p.lastSeenNs = (O - 61) * NS; // mid last seen 61 s before observation
        _post(p, O + 1);
        assertFalse(bell.openReference(FEED, DAY).set, "stale mid is not a reference candidate");
        assertEq(bell.provenRungs(FEED, DAY, false), 1, "but it proves rung 0 out");
        (Bell.Verdict v, Bell.Reason why) = bell.checkLive(FEED);
        assertEq(uint256(v), uint256(Bell.Verdict.WAIT));
        assertEq(uint256(why), uint256(Bell.Reason.MID_STALE));
    }

    // ------------------------------------------------------------------
    // 8. early_close_13ET: 2026-11-27 closes 18:00 UTC; close rung 0 is C - 1
    // ------------------------------------------------------------------
    function test_08_early_close_day_close_reference() public {
        uint32 day = 20261127;
        SessionCalendar.Session memory s = SessionCalendar.sessionForDate(day);
        assertTrue(s.earlyClose);
        uint64 Ce = s.closeUtc; // 18:00 UTC
        P memory last = _p(Ce - 1, 320e18, 2);
        _post(last, Ce - 1);
        P memory afterClose = _p(Ce + 30, 999e18, 3); // post-market print after 13:00 ET
        _post(afterClose, Ce + 35);
        Bell.Candidate memory c = bell.closeReference(FEED, day);
        assertEq(c.observationsTimestamp, uint32(Ce - 1), "close ref is the last regular second before 13:00 ET");
        assertEq(c.rung, 0);
        vm.warp(Ce + N);
        assertEq(uint256(bell.closePhase(FEED, day)), uint256(Bell.Phase.CLOSE_FINAL));
    }

    // ------------------------------------------------------------------
    // 9. session_merge_gap: no overnight reports; next day's OPEN only from its own rungs
    // ------------------------------------------------------------------
    function test_09_sessions_do_not_merge_without_overnight_reports() public {
        _post(_p(C - 1, 318e18, 2), C - 1); // close candidate day 1
        uint32 day2 = 20260910;
        SessionCalendar.Session memory s2 = SessionCalendar.sessionForDate(day2);
        assertFalse(bell.openReference(FEED, day2).set);
        _post(_p(s2.openUtc, 319e18, 2), s2.openUtc + 3);
        assertEq(bell.openReference(FEED, day2).observationsTimestamp, uint32(s2.openUtc));
        assertEq(bell.closeReference(FEED, DAY).observationsTimestamp, uint32(C - 1), "day 1 close untouched");
    }

    // ------------------------------------------------------------------
    // 11. a contradicting statement after the deadline -> WINDOW_CLOSED (no change, no conflict)
    // ------------------------------------------------------------------
    function test_11_after_window_report_does_not_change_final() public {
        _post(_p(O, 316e18, 2), O + 6);
        vm.warp(O + N);
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_FINAL));
        _post(_p(O, 300e18, 2), O + N + 1); // a different statement about rung 0 arrives after the deadline
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertEq(c.mid, 316e18, "final reference is immutable");
        assertFalse(c.conflict, "late evidence cannot even raise a conflict");
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_FINAL));
    }

    // ------------------------------------------------------------------
    // 14. window_boundary_exact: the last rung can be posted until O + N - 1, not at O + N
    // ------------------------------------------------------------------
    function test_14_window_boundary_exact() public {
        _post(_p(O + 7 * R, 316e18, 2), O + N - 1); // last admissible second
        assertTrue(bell.openReference(FEED, DAY).set);
        assertEq(bell.openReference(FEED, DAY).rung, 7);
        bell = new Bell(IVerifierProxy(address(proxy)), new bytes32[](0), new address[](0));
        _post(_p(O + 7 * R, 316e18, 2), O + N); // one second too late
        assertFalse(bell.openReference(FEED, DAY).set);
    }

    // ------------------------------------------------------------------
    // 15. status4_overnight_conservative
    // ------------------------------------------------------------------
    function test_15_overnight_status_never_opens() public {
        _post(_p(O, 316e18, 4), O + 2);
        assertFalse(bell.openReference(FEED, DAY).set);
        (Bell.Verdict v, Bell.Reason why) = bell.checkLive(FEED);
        assertEq(uint256(v), uint256(Bell.Verdict.WAIT));
        assertEq(uint256(why), uint256(Bell.Reason.NON_REGULAR));
    }

    // ------------------------------------------------------------------
    // Guard happy path + settle flow
    // ------------------------------------------------------------------
    function test_live_allow_inside_session_fresh() public {
        _post(_p(O + 600, 316e18, 2), O + 601);
        (Bell.Verdict v, Bell.Reason why) = bell.checkLive(FEED);
        assertEq(uint256(v), uint256(Bell.Verdict.ALLOW));
        assertEq(uint256(why), uint256(Bell.Reason.OK));
        vm.warp(O + 601 + 31);
        (v, why) = bell.checkLive(FEED);
        assertEq(uint256(why), uint256(Bell.Reason.OBS_STALE));
    }

    function test_settle_waits_then_allows_with_receipt() public {
        bytes32 rid = _post(_p(O, 316e18, 2), O + 3);
        (Bell.Verdict v, Bell.Reason why, int192 mid, bytes32 r) = bell.checkSettle(FEED, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.WAIT));
        assertEq(uint256(why), uint256(Bell.Reason.REFERENCE_PENDING));
        vm.warp(O + N);
        (v, why, mid, r) = bell.checkSettle(FEED, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.ALLOW));
        assertEq(mid, 316e18);
        assertEq(r, rid);
    }

    function test_no_session_day_rejects() public {
        (Bell.Verdict v, Bell.Reason why,,) = bell.checkSettle(FEED, 20260703, false);
        assertEq(uint256(v), uint256(Bell.Verdict.REJECT));
        assertEq(uint256(why), uint256(Bell.Reason.NO_SESSION));
    }

    function test_wrong_schema_reverts() public {
        P memory p = _p(O, 316e18, 2);
        p.feedId = 0x000362205e10b3a147d02792eccee483dca6c7b44ecce7012cb8c6e0b68b3ae9; // v3 crypto feed
        vm.warp(O + 2);
        vm.expectRevert(Bell.WrongSchema.selector);
        bell.post(_payload(p));
    }
}
