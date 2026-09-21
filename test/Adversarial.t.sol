// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PushFeedGuard} from "../src/PushFeedGuard.sol";
import {SessionCalendar} from "../src/SessionCalendar.sol";
import {SessionLog} from "../src/SessionLog.sol";
import {SettleOnMark, IERC20} from "../src/SettleOnMark.sol";
import {Aggregator, USDGToken} from "./SettleOnMark.t.sol";

/// Attacks on the money, not on the code.
///
/// Reviewers raised four ways to take value out of a trade that settles on a recorded mark, and every one
/// of them is about who acts and when, not about a bug in a function. Each is written here as a test that
/// runs, so the answer is a transcript rather than an opinion. Two of them fail to steal anything. One of
/// them succeeds, and it is documented in docs/THREAT_MODEL.md rather than quietly fixed with a comment.
///
/// Day used throughout: 2026-09-22 (Tuesday, EDT), O = 13:30:00 UTC, C = 20:00:00 UTC.
contract AdversarialTest is Test {
    PushFeedGuard guard;
    SessionLog sessionLog;
    Aggregator feed;
    USDGToken usdg;
    SettleOnMark trade;

    uint64 constant O = 1790083800;
    uint64 constant C = 1790107200;
    uint32 constant DAY = 20260922;
    int192 constant STRIKE = 33500000000; // 335.00
    uint256 constant STAKE = 1_000_000; // 1 USDG a side
    uint64 constant MAX_AGE = 900;
    uint64 constant MARK_WINDOW = 120;

    address constant LONG = address(0xA11CE);
    address constant SHORT = address(0xB0B);
    address constant STRANGER = address(0xCAFE);

    function setUp() public {
        guard = new PushFeedGuard();
        sessionLog = new SessionLog(guard);
        feed = new Aggregator(33553000000, O + 60);
        usdg = new USDGToken();
        trade = _newTrade(DAY);
        _fundBothSides(trade);
    }

    function _newTrade(uint32 day) internal returns (SettleOnMark t) {
        t = new SettleOnMark(
            sessionLog,
            IERC20(address(usdg)),
            address(feed),
            day,
            STRIKE,
            MAX_AGE,
            MARK_WINDOW,
            STAKE,
            C + 3600,
            LONG,
            SHORT
        );
    }

    function _fundBothSides(SettleOnMark t) internal {
        usdg.mint(LONG, STAKE);
        usdg.mint(SHORT, STAKE);
        vm.warp(O - 60);
        vm.prank(LONG);
        usdg.approve(address(t), STAKE);
        vm.prank(SHORT);
        usdg.approve(address(t), STAKE);
        vm.prank(LONG);
        t.fund();
        vm.prank(SHORT);
        t.fund();
    }

    // ------------------------------------------------------------------------------------------------
    // Attack 1: the losing side controls the keeper and simply refuses to write the mark
    // ------------------------------------------------------------------------------------------------

    /// The mark is permissionless, so refusing to write it censors nothing: the other side, or any
    /// passer-by, writes it instead and the trade settles against the party that stayed silent.
    function test_a_losing_party_cannot_censor_the_closing_mark() public {
        // A closing price above the strike makes LONG the winner, so SHORT is the one with a motive.
        feed.set(34000000000, C - 90);
        vm.warp(C - 60);

        // SHORT never calls. A stranger does, for the price of gas.
        vm.prank(STRANGER);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);

        (address winner,) = trade.settle();
        assertEq(winner, LONG, "silence did not save the losing side");
        assertEq(usdg.balanceOf(LONG), STAKE * 2, "the winner was paid in full");
        assertEq(usdg.balanceOf(SHORT), 0);
    }

    /// The same attack from the other direction: the winner can write the mark themselves, so being the
    /// counterparty of a hostile keeper costs one transaction, not the trade.
    function test_the_winner_can_write_the_mark_without_anyone_s_help() public {
        feed.set(34000000000, C - 90);
        vm.warp(C - 30);
        vm.prank(LONG);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);

        (address winner,) = trade.settle();
        assertEq(winner, LONG);
    }

    // ------------------------------------------------------------------------------------------------
    // Attack 2: the one that works. Nobody writes the mark at all.
    // ------------------------------------------------------------------------------------------------

    /// This attack succeeds, and it is a property of the design rather than a bug: if the winning side is
    /// asleep during the five-minute window and no third party writes the mark either, the day produces
    /// nothing and `refund()` returns both stakes. A loss becomes a draw.
    ///
    /// It cannot be fixed inside the contract: the contract cannot mark a bell that nobody told it about,
    /// and inventing a price is exactly what this repo refuses to do. The mitigation is operational and
    /// belongs in the docs: the mark is cheap, permissionless, and anyone watching may write it.
    function test_silence_from_everyone_turns_a_loss_into_a_draw() public {
        feed.set(34000000000, C - 90); // LONG would have won
        vm.warp(C + 3600 + 1); // past refundAfter, still no mark

        trade.refund();
        assertEq(usdg.balanceOf(LONG), STAKE, "stake returned, not doubled");
        assertEq(usdg.balanceOf(SHORT), STAKE, "the party that would have lost got its money back");
    }

    // ------------------------------------------------------------------------------------------------
    // Attack 3: choosing which second inside the window becomes the mark
    // ------------------------------------------------------------------------------------------------

    /// `markWindow` narrows the choice, it does not remove it. Whoever writes first picks a second inside
    /// `[C - markWindow, C)`, and if the feed publishes twice in that window the two candidates can name
    /// different winners. This test proves the lever is real, with the exact prices that flip it.
    ///
    /// What bounds the damage: the window is 120 seconds by construction, both candidate observations are
    /// onchain and comparable afterwards, and every party can write the mark, so the lever belongs to
    /// whoever is fastest rather than to a privileged role.
    function test_the_second_chosen_inside_the_window_can_decide_the_winner() public {
        // First candidate: 334.90, below the strike, SHORT wins.
        feed.set(33490000000, C - 110);
        vm.warp(C - 100);
        uint256 snapshot = vm.snapshotState();
        vm.prank(SHORT);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);
        (address winnerA,) = trade.settle();
        assertEq(winnerA, SHORT, "the early tick pays SHORT");

        // Same window, same trade, a later tick: 335.10, above the strike, LONG wins.
        vm.revertToState(snapshot);
        feed.set(33510000000, C - 40);
        vm.warp(C - 30);
        vm.prank(LONG);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);
        (address winnerB,) = trade.settle();
        assertEq(winnerB, LONG, "the later tick pays LONG");
        assertTrue(winnerA != winnerB, "the choice of second changed the outcome");
    }

    // ------------------------------------------------------------------------------------------------
    // Attack 4: the guard refuses forever and the money is trapped
    // ------------------------------------------------------------------------------------------------

    /// The objection several reviewers raised about adapters in general: a contract that reverts when the
    /// oracle is inadmissible can block the operation that releases funds, and a safety check becomes a
    /// freeze. Here the exit does not read the oracle at all.
    ///
    /// The harshest version of it: a trading date outside the tabulated calendar years, where
    /// `SessionCalendar` fails closed and no admissible mark can ever exist.
    function test_money_leaves_even_when_the_calendar_can_never_say_yes() public {
        assertFalse(SessionCalendar.sessionForDate(20280315).exists, "2028 is outside the tabulation");

        SettleOnMark stranded = _newTrade(20280315);
        _fundBothSides(stranded);
        assertEq(usdg.balanceOf(address(stranded)), STAKE * 2);

        vm.warp(C + 3600 + 1);
        stranded.refund();
        assertEq(usdg.balanceOf(address(stranded)), 0, "nothing is trapped");
        assertEq(usdg.balanceOf(LONG), STAKE);
        assertEq(usdg.balanceOf(SHORT), STAKE);
    }

    /// A mark that exists but cannot settle must not freeze the stakes either. There are two ways to get
    /// there, and both are tested, because `SessionLog` deliberately records with an unlimited age budget
    /// (`type(uint64).max`): the log states what the session was, and the trade applies its own budget.
    /// So a recorded mark can be refused either by the guard itself or by the trade afterwards.

    /// Path one: the feed answers with a price the guard will not pass at all.
    function test_a_mark_the_guard_refused_does_not_trap_the_stakes() public {
        feed.set(0, C - 90); // BAD_PRICE: a feed answering zero is not a market
        vm.warp(C - 60);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);

        SessionLog.Mark memory m = sessionLog.getMark(address(feed), DAY, SessionLog.Kind.CLOSE);
        assertTrue(m.set, "the mark was recorded");
        assertEq(m.verdict, uint8(PushFeedGuard.Verdict.REJECT), "and the guard refused it");
        assertEq(m.reason, uint8(PushFeedGuard.Reason.BAD_PRICE));

        vm.expectRevert(abi.encodeWithSelector(SettleOnMark.MarkNotAdmissible.selector, m.reason));
        trade.settle();

        vm.warp(C + 3600 + 1);
        trade.refund();
        assertEq(usdg.balanceOf(LONG), STAKE);
        assertEq(usdg.balanceOf(SHORT), STAKE);
    }

    /// Path two: the guard passes the mark, but the price behind it is older than the trade's own budget.
    /// This is the case the log cannot judge and the trade must, and it too ends in a refund, not a lock.
    function test_a_mark_older_than_the_trade_s_budget_does_not_trap_the_stakes() public {
        feed.set(34000000000, O + 1); // last update at the opening bell, marked at the closing one
        vm.warp(C - 60);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);

        SessionLog.Mark memory m = sessionLog.getMark(address(feed), DAY, SessionLog.Kind.CLOSE);
        assertEq(m.verdict, uint8(PushFeedGuard.Verdict.ALLOW), "the log records the session, not the age");
        uint64 age = m.markedAt - m.updatedAt;
        assertGt(age, MAX_AGE, "and that price is far older than the trade allows");

        vm.expectRevert(abi.encodeWithSelector(SettleOnMark.PriceTooOld.selector, age));
        trade.settle();

        vm.warp(C + 3600 + 1);
        trade.refund();
        assertEq(usdg.balanceOf(LONG), STAKE);
        assertEq(usdg.balanceOf(SHORT), STAKE);
    }

    /// And the converse, so the refund path cannot be used as an escape from a loss: while an admissible
    /// mark exists, `refund()` refuses no matter how long the loser waits.
    function test_the_loser_cannot_escape_through_refund() public {
        feed.set(34000000000, C - 90);
        vm.warp(C - 60);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);

        vm.warp(C + 3600 + 1);
        vm.expectRevert(SettleOnMark.StillSettleable.selector);
        vm.prank(SHORT);
        trade.refund();

        (address winner,) = trade.settle();
        assertEq(winner, LONG);
    }
}
