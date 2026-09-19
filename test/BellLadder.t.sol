// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

/// Round-5 critique (second reviewer), section H: a poster must not be able to pick the reference by
/// choosing which DON report to publish. Policy v2 answers with a ladder of calendar-fixed target
/// seconds; every rung has exactly one DON statement, and a skipped rung ends in UNRESOLVED, never in
/// another price. Day: 2026-09-09 (EDT), O = 13:30:00 UTC, C = 20:00:00 UTC.
contract BellLadderTest is Test {
    MockVerifierProxy proxy;
    Bell bell;

    bytes32 constant FEED = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant DIGEST = 0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee;
    uint32 constant DAY = 20260909;
    uint64 constant O = 1788960600;
    uint64 constant C = 1788984000;
    uint64 constant N = 300;
    uint64 constant R = 30;
    uint64 constant NS = 1e9;

    function setUp() public {
        proxy = new MockVerifierProxy();
        bell = new Bell(IVerifierProxy(address(proxy)), new bytes32[](0), new address[](0));
    }

    /// Report covering [validFrom, obs] with the mid last seen at `seenNs`.
    function _rep(uint64 validFrom, uint64 obs, int192 mid, uint32 status, uint64 seenNs)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory reportData = abi.encode(
            FEED,
            uint32(validFrom),
            uint32(obs),
            uint192(0),
            uint192(0),
            uint32(obs + 30 days),
            mid,
            seenNs,
            mid - 1e16,
            int192(100e18),
            mid + 1e16,
            int192(100e18),
            mid,
            status
        );
        bytes32[3] memory ctx = [DIGEST, bytes32(uint256(1)), bytes32(0)];
        return abi.encode(ctx, reportData, new bytes32[](1), new bytes32[](1), bytes32(0));
    }

    function _eligible(uint64 obs, int192 mid) internal pure returns (bytes memory) {
        return _rep(obs, obs, mid, 2, obs * NS);
    }

    function _post(bytes memory payload, uint64 at) internal returns (bytes32) {
        vm.warp(at);
        return bell.post(payload);
    }

    function _openPhase() internal view returns (Bell.Phase) {
        return bell.openPhase(FEED, DAY);
    }

    // ------------------------------------------------------------------
    // H1. The withholding attack: publish rung 1 only, keep rung 0 to yourself
    // ------------------------------------------------------------------
    function test_withholding_rung0_leaves_fixing_unresolved() public {
        _post(_eligible(O + R, 317e18), O + R + 2); // rung 1, a "better" price for the attacker
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertTrue(c.set);
        assertEq(c.rung, 1);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_UNRESOLVED), "rung 0 missing: no reference");
        (Bell.Verdict v, Bell.Reason why,,) = bell.checkSettle(FEED, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.REJECT));
        assertEq(uint256(why), uint256(Bell.Reason.REFERENCE_UNRESOLVED));
        assertEq(bell.tokenizedReference(FEED, DAY, false), 0);
    }

    // ------------------------------------------------------------------
    // H2. Proof chain: rung 0 still pre-market (status 1), rung 1 regular -> FINAL at rung 1
    // ------------------------------------------------------------------
    function test_proof_chain_rung0_premarket_rung1_regular() public {
        _post(_rep(O, O, 315e18, 1, O * NS), O + 1); // DON says pre-market at the bell second
        assertEq(bell.provenRungs(FEED, DAY, false), 1);
        assertFalse(bell.openReference(FEED, DAY).set);
        _post(_eligible(O + R, 316e18), O + R + 1);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
        (Bell.Verdict v,, int192 mid,) = bell.checkSettle(FEED, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.ALLOW));
        assertEq(mid, 316e18);
        assertEq(bell.openReference(FEED, DAY).rung, 1);
    }

    /// The rung-0 case the fixtures make plausible: status 2 at the bell second, but the mid was last seen
    /// 3.264 s earlier (the 38 distinct fixtures trail their own obs by a median of 2.57 s, all of them
    /// mid-session, none at an open). Rung 0 is proven out by the l >= O rule, rung 1 becomes the reference.
    function test_rung0_preopen_mid_proves_rung_out() public {
        _post(_rep(O, O, 315e18, 2, O * NS - 3_264_000_000), O + 1);
        assertEq(bell.provenRungs(FEED, DAY, false), 1);
        _post(_eligible(O + R, 316e18), O + R + 1);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
        assertEq(bell.openReference(FEED, DAY).mid, 316e18);
    }

    // ------------------------------------------------------------------
    // H3. Order independence
    // ------------------------------------------------------------------
    function test_order_proof_after_candidate() public {
        _post(_eligible(O + R, 316e18), O + R + 1); // rung 1 first
        _post(_rep(O, O, 315e18, 1, O * NS), O + R + 2); // rung 0 proof later
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
        assertEq(bell.openReference(FEED, DAY).rung, 1);
    }

    function test_order_lower_candidate_after_higher() public {
        _post(_eligible(O + 2 * R, 318e18), O + 2 * R + 1); // rung 2 first
        _post(_eligible(O + R, 317e18), O + 2 * R + 2); // then rung 1
        _post(_eligible(O, 316e18), O + 2 * R + 3); // then rung 0
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertEq(c.rung, 0);
        assertEq(c.mid, 316e18);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
    }

    function test_higher_rung_after_lower_is_ignored() public {
        _post(_eligible(O, 316e18), O + 1);
        _post(_eligible(O + R, 999e18), O + R + 1);
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertEq(c.rung, 0);
        assertEq(c.mid, 316e18);
        assertFalse(c.conflict);
    }

    // ------------------------------------------------------------------
    // H4. Containment: a report shaped like the mainnet outlier (validFrom = T, obs = T + 1) covers rung T
    // ------------------------------------------------------------------
    function test_report_with_obs_one_second_after_target_covers_rung() public {
        _post(_rep(O, O + 1, 316e18, 2, (O + 1) * NS), O + 2);
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertTrue(c.set);
        assertEq(c.rung, 0);
        assertEq(c.observationsTimestamp, uint32(O + 1));
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
    }

    /// A wide report covering rungs 0 and 1 is one statement: candidate at rung 0, rung 1 not needed.
    function test_wide_report_takes_lowest_rung() public {
        _post(_rep(O, O + R, 316e18, 2, (O + R) * NS), O + R + 1);
        assertEq(bell.openReference(FEED, DAY).rung, 0);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
    }

    // ------------------------------------------------------------------
    // H5. Safety net: two different DON statements covering the same rung -> conflict -> UNRESOLVED
    // ------------------------------------------------------------------
    function test_two_distinct_reports_covering_rung_conflict() public {
        _post(_rep(O, O, 316e18, 2, O * NS), O + 1);
        _post(_rep(O, O + 1, 317e18, 2, (O + 1) * NS), O + 2); // overlaps the same target second
        assertTrue(bell.openReference(FEED, DAY).conflict);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    function test_proof_then_eligible_same_rung_conflict() public {
        _post(_rep(O, O, 315e18, 1, O * NS), O + 1); // rung 0 proven out
        _post(_eligible(O, 316e18), O + 2); // a second statement says rung 0 was regular
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertTrue(c.set);
        assertTrue(c.conflict);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    function test_eligible_then_proof_same_rung_conflict() public {
        _post(_eligible(O, 316e18), O + 1);
        _post(_rep(O, O, 315e18, 1, O * NS), O + 2);
        assertTrue(bell.openReference(FEED, DAY).conflict);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    /// A conflict at a higher rung is moot once a clean lower rung arrives.
    function test_conflict_at_higher_rung_is_moot_after_clean_lower_rung() public {
        _post(_eligible(O + R, 317e18), O + R + 1);
        _post(_rep(O + R, O + R, 318e18, 2, (O + R) * NS), O + R + 2); // conflict at rung 1
        assertTrue(bell.openReference(FEED, DAY).conflict);
        _post(_eligible(O, 316e18), O + R + 3);
        Bell.Candidate memory c = bell.openReference(FEED, DAY);
        assertEq(c.rung, 0);
        assertFalse(c.conflict);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
    }

    // ------------------------------------------------------------------
    // H6. Seconds that are not rungs are never evidence
    // ------------------------------------------------------------------
    function test_non_rung_second_is_never_a_candidate() public {
        bytes32 rid = _post(_eligible(O + 3, 316e18), O + 4);
        assertFalse(bell.openReference(FEED, DAY).set);
        assertEq(bell.provenRungs(FEED, DAY, false), 0);
        assertEq(bell.receipt(rid).phase, 0, "stored as latest, not as fixing evidence");
        (,,, uint32 obs,,,,,) = bell.latest(FEED);
        assertEq(obs, uint32(O + 3), "latest still updated");
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    function test_second_beyond_last_rung_is_not_evidence() public {
        _post(_eligible(O + 8 * R, 316e18), O + 8 * R + 1); // would be rung 8
        assertFalse(bell.openReference(FEED, DAY).set);
    }

    /// Full ladder: rungs 0..6 proven out, rung 7 regular -> FINAL at rung 7 (target O + 210 s).
    function test_full_ladder_to_last_rung() public {
        for (uint64 i = 0; i < 7; i++) {
            _post(_rep(O + i * R, O + i * R, 315e18, 1, (O + i * R) * NS), O + i * R + 1);
        }
        assertEq(bell.provenRungs(FEED, DAY, false), 0x7f);
        _post(_eligible(O + 7 * R, 316e18), O + 7 * R + 1);
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_FINAL));
        assertEq(bell.openReference(FEED, DAY).rung, 7);
    }

    /// One missing proof in the middle breaks the chain.
    function test_gap_in_proof_chain_is_unresolved() public {
        _post(_rep(O, O, 315e18, 1, O * NS), O + 1); // rung 0 proven
        // rung 1 withheld
        _post(_eligible(O + 2 * R, 316e18), O + 2 * R + 1); // rung 2 candidate
        vm.warp(O + N);
        assertEq(uint256(_openPhase()), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    // ------------------------------------------------------------------
    // H7. CLOSE mirrors the ladder downwards from C - 1
    // ------------------------------------------------------------------
    function test_close_withholding_rung0_unresolved() public {
        _post(_eligible(C - 1 - R, 320e18), C - R); // close rung 1 only
        assertEq(bell.closeReference(FEED, DAY).rung, 1);
        vm.warp(C + N);
        assertEq(uint256(bell.closePhase(FEED, DAY)), uint256(Bell.Phase.CLOSE_UNRESOLVED));
    }

    function test_close_proof_chain() public {
        // rung 0 (C - 1): status 2 but the mid was last seen after C (post-close update): proves rung 0 out
        _post(_rep(C - 1, C - 1, 320e18, 2, C * NS + 500_000_000), C + 1);
        assertEq(bell.provenRungs(FEED, DAY, true), 1);
        _post(_eligible(C - 1 - R, 319e18), C + 2);
        vm.warp(C + N);
        assertEq(uint256(bell.closePhase(FEED, DAY)), uint256(Bell.Phase.CLOSE_FINAL));
        (Bell.Verdict v,, int192 mid,) = bell.checkSettle(FEED, DAY, true);
        assertEq(uint256(v), uint256(Bell.Verdict.ALLOW));
        assertEq(mid, 319e18);
    }

    function test_close_rung0_regular_is_final() public {
        _post(_eligible(C - 1, 320e18), C - 1);
        vm.warp(C + N);
        assertEq(uint256(bell.closePhase(FEED, DAY)), uint256(Bell.Phase.CLOSE_FINAL));
        assertEq(bell.closeReference(FEED, DAY).rung, 0);
    }

    /// A report observed at or after C never qualifies for CLOSE even if it covers C - 1.
    function test_close_report_observed_after_close_is_not_eligible() public {
        _post(_rep(C - 1, C + 1, 320e18, 2, (C - 1) * NS), C + 2);
        assertFalse(bell.closeReference(FEED, DAY).set);
        assertEq(bell.provenRungs(FEED, DAY, true), 1, "covers C - 1, so it proves rung 0 out");
    }
}
