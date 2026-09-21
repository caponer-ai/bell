// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PushFeedGuard} from "../src/PushFeedGuard.sol";
import {SettlementPairGuard} from "../src/SettlementPairGuard.sol";

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

/// The case our own policy comparison found against us, turned into tests.
///
/// On 2026-08-25 two settlements (PLTR and AMD) locked and settled four and eleven seconds apart, inside
/// the regular session, on a price four and eight minutes old. Every per-read check passes. Both reads
/// returned the same feed round, so the market's tie rule decided the outcome and the guard let it
/// through. Day used here: 2026-09-22, O = 13:30:00 UTC, C = 20:00:00 UTC.
contract SettlementPairGuardTest is Test {
    PushFeedGuard guard;
    SettlementPairGuard pair;
    Aggregator feed;

    uint64 constant O = 1790083800;
    uint64 constant MAX_AGE = 900;
    int256 constant PRICE = 17766000000; // 177.66, the PLTR print from that day

    function setUp() public {
        guard = new PushFeedGuard();
        pair = new SettlementPairGuard(guard);
        feed = new Aggregator(PRICE, O + 60);
    }

    /// The exact shape of the PLTR case: lock, then settle four seconds later on the same observation.
    function test_second_read_on_the_same_observation_is_rejected() public {
        vm.warp(O + 540); // eight minutes after the print, well inside the budget
        (SettlementPairGuard.Verdict first, uint8 firstReason,, uint256 firstUpdatedAt) =
            pair.checkFirstRead(address(feed), MAX_AGE);
        assertEq(uint256(first), uint256(SettlementPairGuard.Verdict.ALLOW), "the first read is fine");
        assertEq(firstReason, 0);

        vm.warp(O + 544); // four seconds later, as in the audited settlement
        (SettlementPairGuard.Verdict second, SettlementPairGuard.Reason reason,,,) =
            pair.checkSecondRead(address(feed), MAX_AGE, firstUpdatedAt);
        assertEq(uint256(second), uint256(SettlementPairGuard.Verdict.REJECT));
        assertEq(uint256(reason), uint256(SettlementPairGuard.Reason.SAME_OBSERVATION));
    }

    function test_a_new_observation_between_the_reads_is_admissible() public {
        vm.warp(O + 540);
        (,,, uint256 firstUpdatedAt) = pair.checkFirstRead(address(feed), MAX_AGE);

        feed.set(PRICE + 25000000, O + 600); // the feed publishes a new round
        vm.warp(O + 640);
        (SettlementPairGuard.Verdict v, SettlementPairGuard.Reason reason,, int256 answer, uint256 u) =
            pair.checkSecondRead(address(feed), MAX_AGE, firstUpdatedAt);
        assertEq(uint256(v), uint256(SettlementPairGuard.Verdict.ALLOW));
        assertEq(uint256(reason), uint256(SettlementPairGuard.Reason.OK));
        assertEq(answer, PRICE + 25000000);
        assertTrue(u != firstUpdatedAt, "a different observation");
    }

    function test_the_per_read_guard_still_speaks_first() public {
        feed.set(PRICE, O - 300); // a price from before the bell, so nothing is stamped in the future
        vm.warp(O - 60); // before the bell: the session check must win over the pair rule
        (SettlementPairGuard.Verdict v, SettlementPairGuard.Reason reason, uint8 guardReason,,) =
            pair.checkSecondRead(address(feed), MAX_AGE, 0);
        assertEq(uint256(v), uint256(SettlementPairGuard.Verdict.REJECT));
        assertEq(uint256(reason), uint256(SettlementPairGuard.Reason.GUARD_REFUSED));
        assertEq(guardReason, uint8(PushFeedGuard.Reason.OUTSIDE_SESSION));
    }

    function test_zero_skips_the_pair_rule_for_a_standalone_read() public {
        vm.warp(O + 540);
        (SettlementPairGuard.Verdict v, SettlementPairGuard.Reason reason,,,) =
            pair.checkSecondRead(address(feed), MAX_AGE, 0);
        assertEq(uint256(v), uint256(SettlementPairGuard.Verdict.ALLOW));
        assertEq(uint256(reason), uint256(SettlementPairGuard.Reason.OK));
    }

    function test_require_variant_reverts_with_both_reasons() public {
        vm.warp(O + 540);
        (,,, uint256 firstUpdatedAt) = pair.checkFirstRead(address(feed), MAX_AGE);
        vm.warp(O + 544);
        vm.expectRevert(
            abi.encodeWithSelector(
                SettlementPairGuard.NotAdmissible.selector,
                uint8(SettlementPairGuard.Reason.SAME_OBSERVATION),
                uint8(PushFeedGuard.Reason.OK)
            )
        );
        pair.requireSecondRead(address(feed), MAX_AGE, firstUpdatedAt);
    }

    function test_require_variant_passes_a_good_pair() public {
        vm.warp(O + 540);
        (,,, uint256 firstUpdatedAt) = pair.checkFirstRead(address(feed), MAX_AGE);
        feed.set(PRICE + 1, O + 700);
        vm.warp(O + 720);
        (int256 answer, uint256 u) = pair.requireSecondRead(address(feed), MAX_AGE, firstUpdatedAt);
        assertEq(answer, PRICE + 1);
        assertEq(u, O + 700);
    }

    /// A stale price is still refused by the per-read guard, so the pair rule never has to see it.
    function test_a_stale_pair_is_refused_by_the_guard_not_the_pair_rule() public {
        vm.warp(O + 60 + MAX_AGE + 10);
        (SettlementPairGuard.Verdict v, SettlementPairGuard.Reason reason, uint8 guardReason,,) =
            pair.checkSecondRead(address(feed), MAX_AGE, 12345);
        assertEq(uint256(v), uint256(SettlementPairGuard.Verdict.WAIT));
        assertEq(uint256(reason), uint256(SettlementPairGuard.Reason.GUARD_REFUSED));
        assertEq(guardReason, uint8(PushFeedGuard.Reason.PRICE_STALE));
    }
}
