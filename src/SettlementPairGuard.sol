// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PushFeedGuard} from "./PushFeedGuard.sol";

/// @title SettlementPairGuard
/// @notice The rule `PushFeedGuard` cannot express on its own: two reads that decide one settlement must
///         not be the same observation.
///
/// This contract exists because our own measurement said it should. `script/policy_comparison.py` runs the
/// 30 audited settlements through four policies, and on 2026-08-25 it found two settlements (PLTR and AMD)
/// where a five-line local patch is **stricter** than the deployed guard: both reads happened inside the
/// regular session on a price four and eight minutes old, so every per-read check passes, yet the two
/// reads were four and eleven seconds apart and returned the *same feed round*. The market's outcome was
/// therefore decided by its tie rule, and a guard that only judges each read in isolation lets it through.
///
/// A per-read guard is the wrong shape for that question, because the defect is a relationship between two
/// reads. So the pair rule lives here, one small stateless contract on top of the existing one: the caller
/// passes the `updatedAt` it saw on the first read, and this returns `SAME_OBSERVATION` when the second
/// read carries the same one.
///
/// Comparing `updatedAt` is sound for this purpose on these feeds: a new round writes a new timestamp, so
/// an unchanged `updatedAt` means no new round was published between the two reads. It does not prove the
/// price did not move on the exchange in between, and nothing onchain can prove that.
///
/// No owner, no upgrade, no state.
contract SettlementPairGuard {
    PushFeedGuard public immutable GUARD;

    enum Verdict {
        ALLOW,
        WAIT,
        REJECT
    }

    enum Reason {
        OK,
        GUARD_REFUSED, // the per-read guard already refused: its own reason is returned alongside
        SAME_OBSERVATION // both reads carry one observation, so the pair cannot decide anything
    }

    error NotAdmissible(uint8 reason, uint8 guardReason);

    constructor(PushFeedGuard guard) {
        GUARD = guard;
    }

    /// @notice Judge the second read of a settlement pair.
    /// @param feed the aggregator both reads used
    /// @param maxAge the caller's staleness budget, in seconds
    /// @param firstUpdatedAt the `updatedAt` returned by the first read (0 to skip the pair rule)
    function checkSecondRead(address feed, uint64 maxAge, uint256 firstUpdatedAt)
        public
        view
        returns (Verdict verdict, Reason reason, uint8 guardReason, int256 answer, uint256 updatedAt)
    {
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r, int256 a, uint256 u) = GUARD.check(feed, maxAge);
        if (v != PushFeedGuard.Verdict.ALLOW) {
            return (Verdict(uint8(v)), Reason.GUARD_REFUSED, uint8(r), a, u);
        }
        if (firstUpdatedAt != 0 && u == firstUpdatedAt) {
            return (Verdict.REJECT, Reason.SAME_OBSERVATION, uint8(PushFeedGuard.Reason.OK), a, u);
        }
        return (Verdict.ALLOW, Reason.OK, uint8(PushFeedGuard.Reason.OK), a, u);
    }

    /// @notice Same rule, reverting, for a settlement path that should stop rather than branch.
    function requireSecondRead(address feed, uint64 maxAge, uint256 firstUpdatedAt)
        external
        view
        returns (int256 answer, uint256 updatedAt)
    {
        (Verdict v, Reason reason, uint8 guardReason, int256 a, uint256 u) =
            checkSecondRead(feed, maxAge, firstUpdatedAt);
        if (v != Verdict.ALLOW) revert NotAdmissible(uint8(reason), guardReason);
        return (a, u);
    }

    /// @notice Convenience for the first read of a pair: plain per-read admissibility.
    function checkFirstRead(address feed, uint64 maxAge)
        external
        view
        returns (Verdict verdict, uint8 guardReason, int256 answer, uint256 updatedAt)
    {
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r, int256 a, uint256 u) = GUARD.check(feed, maxAge);
        return (Verdict(uint8(v)), uint8(r), a, u);
    }
}
