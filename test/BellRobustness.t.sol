// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

/// Minimal USDG stand-in (6 decimals, like Paxos USDG) for the payout invariants below.
contract MockUSDG {
    string public constant symbol = "USDG";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A settlement stripped to the one line that matters for these tests: the money that leaves escrow is a
/// function of Bell's session reference price and nothing else. The Settle-mini demo will replace this stub,
/// but the invariant it is used to state ("the payout does not move") is the same one the demo must keep.
contract PayoutStub {
    Bell public immutable BELL;
    MockUSDG public immutable USDG;
    bytes32 public immutable FEED;
    uint256 public immutable QTY; // shares, 6 decimals (1e6 = one share)

    error NotSettleable(uint8 reason);

    constructor(Bell bell, MockUSDG usdg, bytes32 feedId, uint256 qty) {
        BELL = bell;
        USDG = usdg;
        FEED = feedId;
        QTY = qty;
    }

    /// @notice Payout in USDG units: qty * reference mid. Reverts unless Bell says ALLOW.
    function settle(uint32 tradingDate, bool isClose, address to) external returns (uint256 amount) {
        (Bell.Verdict v, Bell.Reason why, int192 mid,) = BELL.checkSettle(FEED, tradingDate, isClose);
        if (v != Bell.Verdict.ALLOW) revert NotSettleable(uint8(why));
        amount = QTY * uint256(uint192(mid)) / 1e18;
        USDG.transfer(to, amount);
    }

    /// @notice Payout without moving money: 0 means "Bell would not let this settle".
    function quote(uint32 tradingDate, bool isClose) external view returns (uint256) {
        (Bell.Verdict v,, int192 mid,) = BELL.checkSettle(FEED, tradingDate, isClose);
        if (v != Bell.Verdict.ALLOW) return 0;
        return QTY * uint256(uint192(mid)) / 1e18;
    }
}

/// Council decision 2026-09-19: prove the ladder is robust as a *payout* rule, not only as a state machine.
/// The same signed reports, permuted, delayed, duplicated and withheld, must never produce a different
/// payout. The only freedom a poster has is publish or not, and withholding ends in "no payout", never in
/// "another payout".
///
/// Trading day: 2026-09-09 (EDT), O = 13:30:00 UTC = 1788960600, C = 20:00:00 UTC. Rungs: O + 30 i.
///
/// Evidence set (all five are DON statements a poster could hold back):
///   0  A: rung 0, status 2, mid last seen 3.264 s before the bell -> ineligible, proves rung 0 out
///   1  B: rung 1, eligible, mid 316.0 -> the reference
///   2  C: rung 2, eligible, mid 317.0 -> a higher rung, must never be the payout
///   3  D: rung 3, status 4 (overnight) -> proves rung 3 out, irrelevant to the payout
///   4  E: byte-identical replay of B
contract BellRobustnessTest is Test {
    bytes32 constant FEED = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant DIGEST = 0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee;
    uint32 constant DAY = 20260909;
    uint64 constant O = 1788960600;
    uint64 constant WINDOW = 300;
    uint64 constant R = 30;
    uint64 constant NS = 1e9;

    uint256 constant N = 5; // size of the evidence set
    uint256 constant QTY = 2e6; // two shares, 6 decimals
    int192 constant MID_REF = 316e18; // rung 1
    int192 constant MID_HIGH = 317e18; // rung 2, must never be paid
    uint256 constant CANONICAL = 632e6; // 2 shares * 316.0 USDG

    address constant PAYEE = address(0xBEEF);

    // ------------------------------------------------------------------
    // Builders
    // ------------------------------------------------------------------

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

    function _evidence(uint256 i) internal pure returns (bytes memory) {
        if (i == 0) return _rep(O, O, 315e18, 2, O * NS - 3_264_000_000); // pre-bell mid: proves rung 0 out
        if (i == 1) return _rep(O + R, O + R, MID_REF, 2, (O + R) * NS);
        if (i == 2) return _rep(O + 2 * R, O + 2 * R, MID_HIGH, 2, (O + 2 * R) * NS);
        if (i == 3) return _rep(O + 3 * R, O + 3 * R, 318e18, 4, (O + 3 * R) * NS); // overnight status
        return _rep(O + R, O + R, MID_REF, 2, (O + R) * NS); // E == B, byte-identical replay
    }

    /// Observation second of evidence i, used to pick a legal posting time.
    function _obs(uint256 i) internal pure returns (uint64) {
        if (i == 0) return O;
        if (i == 1) return O + R;
        if (i == 2) return O + 2 * R;
        if (i == 3) return O + 3 * R;
        return O + R;
    }

    /// Fresh Bell + payout stub for one scenario (state must never leak between scenarios).
    function _fresh() internal returns (Bell bell, PayoutStub stub) {
        MockVerifierProxy proxy = new MockVerifierProxy();
        bell = new Bell(IVerifierProxy(address(proxy)), new bytes32[](0), new address[](0));
        MockUSDG usdg = new MockUSDG();
        stub = new PayoutStub(bell, usdg, FEED, QTY);
        usdg.mint(address(stub), 100_000e6);
    }

    /// Posts the listed evidence in the listed order at the listed times, then returns the payout Bell
    /// allows once the fixing is immutable (t >= O + WINDOW).
    function _run(uint256[] memory order, uint64[] memory times) internal returns (uint256 payout) {
        (Bell bell, PayoutStub stub) = _fresh();
        for (uint256 k = 0; k < order.length; k++) {
            vm.warp(times[k]);
            bell.post(_evidence(order[k]));
        }
        vm.warp(O + WINDOW + 1);
        return stub.quote(DAY, false);
    }

    /// Default posting time for evidence i: as early as the report is postable.
    function _timesEarliest(uint256[] memory order) internal pure returns (uint64[] memory times) {
        times = new uint64[](order.length);
        for (uint256 k = 0; k < order.length; k++) {
            times[k] = _obs(order[k]) + 1;
        }
    }

    function _seq(uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = i;
        }
    }

    function _fact(uint256 n) internal pure returns (uint256 f) {
        f = 1;
        for (uint256 i = 2; i <= n; i++) {
            f *= i;
        }
    }

    /// k-th permutation of 0..n-1 in factorial number system order.
    function _perm(uint256 k, uint256 n) internal pure returns (uint256[] memory out) {
        uint256[] memory pool = _seq(n);
        uint256 len = n;
        out = new uint256[](n);
        uint256 rem = k;
        for (uint256 i = 0; i < n; i++) {
            uint256 f = _fact(len - 1);
            uint256 idx = rem / f;
            rem = rem % f;
            out[i] = pool[idx];
            for (uint256 j = idx; j + 1 < len; j++) {
                pool[j] = pool[j + 1];
            }
            len--;
        }
    }

    // ------------------------------------------------------------------
    // R0. The canonical scenario: the whole evidence set pays 632 USDG
    // ------------------------------------------------------------------

    function test_canonical_payout_moves_real_tokens() public {
        (Bell bell, PayoutStub stub) = _fresh();
        for (uint256 i = 0; i < N; i++) {
            vm.warp(_obs(i) + 1);
            bell.post(_evidence(i));
        }
        vm.warp(O + WINDOW + 1);
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_FINAL), "fixing must be FINAL");
        assertEq(bell.openReference(FEED, DAY).rung, 1, "reference sits on rung 1");

        uint256 paid = stub.settle(DAY, false, PAYEE);
        assertEq(paid, CANONICAL, "2 shares * 316.0 = 632 USDG");
        assertEq(stub.USDG().balanceOf(PAYEE), CANONICAL, "USDG actually moved");
    }

    // ------------------------------------------------------------------
    // R1. Permutations: all 120 orderings of the five reports pay the same
    // ------------------------------------------------------------------

    function test_every_permutation_pays_the_same() public {
        uint256 total = _fact(N);
        for (uint256 k = 0; k < total; k++) {
            uint256[] memory order = _perm(k, N);
            uint256 payout = _run(order, _timesEarliest(order));
            assertEq(payout, CANONICAL, "payout depends on posting order");
        }
    }

    // ------------------------------------------------------------------
    // R2. Delays: when each report is posted inside the window does not matter
    // ------------------------------------------------------------------

    function test_delays_inside_the_window_do_not_move_the_payout() public {
        uint256[] memory order = _seq(N);

        // (a) everything as early as possible
        assertEq(_run(order, _timesEarliest(order)), CANONICAL, "earliest posts");

        // (b) everything in the last second of the posting window
        uint64[] memory late = new uint64[](N);
        for (uint256 i = 0; i < N; i++) {
            late[i] = O + WINDOW - 1;
        }
        assertEq(_run(order, late), CANONICAL, "all posts at O + 299");

        // (c) staggered: each report 40 s later than the one before, still inside the window
        uint64[] memory staggered = new uint64[](N);
        for (uint256 i = 0; i < N; i++) {
            staggered[i] = O + 100 + uint64(i) * 40;
        }
        assertEq(_run(order, staggered), CANONICAL, "staggered posts");

        // (d) reverse order with late posting: the rung-1 report arrives last, 4 minutes after the bell
        uint256[] memory rev = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            rev[i] = N - 1 - i;
        }
        uint64[] memory revTimes = new uint64[](N);
        for (uint256 i = 0; i < N; i++) {
            revTimes[i] = O + 240 + uint64(i);
        }
        assertEq(_run(rev, revTimes), CANONICAL, "reverse order, late posts");
    }

    // ------------------------------------------------------------------
    // R3. Withholding: any subset pays either the same price or nothing at all
    // ------------------------------------------------------------------

    function test_every_subset_pays_the_canonical_price_or_nothing() public {
        uint256 resolved;
        for (uint256 mask = 0; mask < (1 << N); mask++) {
            uint256 count;
            for (uint256 i = 0; i < N; i++) {
                if ((mask >> i) & 1 == 1) count++;
            }
            uint256[] memory subset = new uint256[](count);
            uint256 j;
            for (uint256 i = 0; i < N; i++) {
                if ((mask >> i) & 1 == 1) {
                    subset[j++] = i;
                }
            }
            uint256 payout = _run(subset, _timesEarliest(subset));
            if (payout != 0) {
                assertEq(payout, CANONICAL, "a subset produced a different price");
                resolved++;
            }
        }
        // Sanity: withholding is a real lever, so some subsets must fail to resolve, and some must resolve.
        assertGt(resolved, 0, "no subset resolved: the test proves nothing");
        assertLt(resolved, 1 << N, "every subset resolved: withholding is not being tested");
    }

    /// The attacker's version of the same property: publish only the rung-2 report, which is 1.0 USD higher.
    /// The ladder must refuse to settle rather than pay the price the poster prefers.
    function test_poster_cannot_lift_the_payout_by_publishing_a_higher_rung() public {
        uint256[] memory only2 = new uint256[](1);
        only2[0] = 2;
        assertEq(_run(only2, _timesEarliest(only2)), 0, "rung 2 alone must not settle");

        // Even with the rung-3 proof added, the chain below rung 2 is incomplete.
        uint256[] memory two = new uint256[](2);
        two[0] = 2;
        two[1] = 3;
        assertEq(_run(two, _timesEarliest(two)), 0, "rungs 2+3 must not settle");
    }

    // ------------------------------------------------------------------
    // R4. Replays and duplicates change nothing
    // ------------------------------------------------------------------

    function test_replaying_the_whole_set_is_idempotent() public {
        (Bell bell, PayoutStub stub) = _fresh();
        bytes32[] memory ids = new bytes32[](N);
        for (uint256 i = 0; i < N; i++) {
            vm.warp(_obs(i) + 1);
            ids[i] = bell.post(_evidence(i));
        }
        uint64[] memory acceptedAt = new uint64[](N);
        for (uint256 i = 0; i < N; i++) {
            acceptedAt[i] = bell.receipt(ids[i]).acceptedAt;
        }

        // Post everything again, in reverse, later in the window.
        for (uint256 i = 0; i < N; i++) {
            vm.warp(O + 200 + uint64(i));
            bytes32 again = bell.post(_evidence(N - 1 - i));
            assertEq(again, ids[N - 1 - i], "receipt id must be the payload hash");
        }
        for (uint256 i = 0; i < N; i++) {
            assertEq(bell.receipt(ids[i]).acceptedAt, acceptedAt[i], "replay rewrote a receipt");
        }

        vm.warp(O + WINDOW + 1);
        assertEq(stub.quote(DAY, false), CANONICAL, "replay moved the payout");
    }

    // ------------------------------------------------------------------
    // R5. After the deadline nothing can move the payout
    // ------------------------------------------------------------------

    function test_late_reports_cannot_move_a_settled_payout() public {
        (Bell bell, PayoutStub stub) = _fresh();
        vm.warp(O + 1);
        bell.post(_evidence(0));
        vm.warp(O + R + 1);
        bell.post(_evidence(1));
        vm.warp(O + WINDOW + 1);
        assertEq(stub.quote(DAY, false), CANONICAL, "baseline");

        // A conflicting statement for rung 1, and a report for rung 2, both after the deadline.
        vm.warp(O + WINDOW + 60);
        bell.post(_rep(O + R, O + R, 320e18, 2, (O + R) * NS)); // same rung, different price
        bell.post(_evidence(2));
        assertEq(stub.quote(DAY, false), CANONICAL, "a late report changed a settled payout");

        uint256 paid = stub.settle(DAY, false, PAYEE);
        assertEq(paid, CANONICAL, "settlement paid a late-modified price");
    }

    /// Mirror of R5 on the unresolved side: a fixing that ended UNRESOLVED cannot be revived later.
    function test_late_reports_cannot_revive_an_unresolved_fixing() public {
        (Bell bell, PayoutStub stub) = _fresh();
        vm.warp(O + R + 1);
        bell.post(_evidence(1)); // rung 1 only: rung 0 was withheld
        vm.warp(O + WINDOW + 1);
        assertEq(stub.quote(DAY, false), 0, "withheld rung 0 must leave it unresolved");

        vm.warp(O + WINDOW + 120);
        bell.post(_evidence(0)); // the withheld rung-0 proof, too late
        assertEq(stub.quote(DAY, false), 0, "a late proof revived a dead fixing");
        assertEq(uint256(bell.openPhase(FEED, DAY)), uint256(Bell.Phase.OPEN_UNRESOLVED));
    }

    // ------------------------------------------------------------------
    // R7. The fixtures we hold cover no rung at all (stated as a test, not as prose)
    // ------------------------------------------------------------------

    /// The 19 observation seconds of our 38 real mainnet fixtures (2026-09-08 and 2026-09-09). Even giving
    /// every one of them the widest window we ever saw (two seconds, [obs - 1, obs]), not one covers a rung
    /// target of either day. That is why no fixture can settle a fixing, and why the open-window behaviour
    /// of the ladder is still unmeasured: it needs reports requested at the bell, i.e. a paid stream.
    function test_no_real_fixture_second_covers_a_ladder_rung() public {
        uint64[19] memory obs = [
            uint64(1788880200),
            1788880800,
            1788881400,
            1788883200,
            1788885000,
            1788886800,
            1788888600,
            1788890400,
            1788892200,
            1788894000,
            1788895800,
            1788962401,
            1788964200,
            1788966000,
            1788967800,
            1788969600,
            1788970801,
            1788975600,
            1788976800
        ];
        uint32[2] memory tradingDays = [uint32(20260908), uint32(20260909)];
        (Bell bell,) = _fresh();

        uint256 covered;
        for (uint256 d = 0; d < tradingDays.length; d++) {
            for (uint8 i = 0; i < 8; i++) {
                uint64 openTarget = bell.rungTarget(tradingDays[d], false, i);
                uint64 closeTarget = bell.rungTarget(tradingDays[d], true, i);
                assertGt(openTarget, 0, "session must exist on a weekday");
                for (uint256 k = 0; k < obs.length; k++) {
                    // widest window seen in the fixtures: [obs - 1, obs]
                    if (obs[k] - 1 <= openTarget && openTarget <= obs[k]) covered++;
                    if (obs[k] - 1 <= closeTarget && closeTarget <= obs[k]) covered++;
                }
            }
        }
        assertEq(covered, 0, "a fixture covers a rung: re-measure before repeating the claim in the README");
    }

    // ------------------------------------------------------------------
    // R6. Two different DON statements on one rung: refuse, in any order
    // ------------------------------------------------------------------

    function test_same_rung_conflict_refuses_in_both_orders() public {
        bytes memory other = _rep(O + R, O + R, 320e18, 2, (O + R) * NS);

        (Bell bellA, PayoutStub stubA) = _fresh();
        vm.warp(O + 1);
        bellA.post(_evidence(0));
        vm.warp(O + R + 1);
        bellA.post(_evidence(1));
        bellA.post(other);
        vm.warp(O + WINDOW + 1);
        assertEq(stubA.quote(DAY, false), 0, "conflict must not settle (A before B)");

        (Bell bellB, PayoutStub stubB) = _fresh();
        vm.warp(O + 1);
        bellB.post(_evidence(0));
        vm.warp(O + R + 1);
        bellB.post(other);
        bellB.post(_evidence(1));
        vm.warp(O + WINDOW + 1);
        assertEq(stubB.quote(DAY, false), 0, "conflict must not settle (B before A)");
    }
}
