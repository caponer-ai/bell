// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PushFeedGuard} from "../src/PushFeedGuard.sol";
import {SessionLog} from "../src/SessionLog.sol";
import {SettleOnMark, IERC20} from "../src/SettleOnMark.sol";

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

contract USDGToken {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Day 2026-09-22 (Tuesday, EDT): O = 13:30:00 UTC, C = 20:00:00 UTC.
contract SettleOnMarkTest is Test {
    PushFeedGuard guard;
    SessionLog sessionLog;
    Aggregator feed;
    USDGToken usdg;
    SettleOnMark trade;

    uint64 constant O = 1790083800;
    uint64 constant C = 1790107200;
    uint32 constant DAY = 20260922;
    int192 constant STRIKE = 33500000000; // 335.00, 8 decimals like the feed
    uint256 constant STAKE = 1_000_000; // 1 USDG a side
    uint64 constant MAX_AGE = 900;
    uint64 constant MARK_WINDOW = 120; // the close mark must sit within two minutes of the bell

    address constant LONG = address(0xA11CE);
    address constant SHORT = address(0xB0B);

    function setUp() public {
        guard = new PushFeedGuard();
        sessionLog = new SessionLog(guard);
        feed = new Aggregator(33553000000, O + 60);
        usdg = new USDGToken();
        trade = new SettleOnMark(
            sessionLog,
            IERC20(address(usdg)),
            address(feed),
            DAY,
            STRIKE,
            MAX_AGE,
            MARK_WINDOW,
            STAKE,
            C + 3600,
            LONG,
            SHORT
        );
        usdg.mint(LONG, STAKE);
        usdg.mint(SHORT, STAKE);
        vm.warp(O - 60);
        vm.prank(LONG);
        usdg.approve(address(trade), STAKE);
        vm.prank(SHORT);
        usdg.approve(address(trade), STAKE);
        vm.prank(LONG);
        trade.fund();
        vm.prank(SHORT);
        trade.fund();
    }

    function _markClose(int256 price, uint64 updatedAt, uint64 at) internal {
        feed.set(price, updatedAt);
        vm.warp(at);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);
    }

    // ------------------------------------------------------------------
    // The happy path: a real closing mark moves real money
    // ------------------------------------------------------------------
    function test_long_wins_when_the_close_is_above_the_strike() public {
        _markClose(33800000000, C - 120, C - 60); // 338.00, two minutes old at the mark
        (bool ok,, int192 price, uint64 age, address winner) = trade.quote();
        assertTrue(ok);
        assertEq(price, 33800000000);
        assertEq(age, 60);
        assertEq(winner, LONG);

        (address w, int192 closing) = trade.settle();
        assertEq(w, LONG);
        assertEq(closing, 33800000000);
        assertEq(usdg.balanceOf(LONG), 2 * STAKE);
        assertEq(usdg.balanceOf(address(trade)), 0);
    }

    function test_short_wins_when_the_close_is_below_the_strike() public {
        _markClose(33000000000, C - 90, C - 30);
        (address w,) = trade.settle();
        assertEq(w, SHORT);
        assertEq(usdg.balanceOf(SHORT), 2 * STAKE);
    }

    function test_exactly_at_the_strike_pays_the_long() public {
        _markClose(STRIKE, C - 90, C - 30);
        (address w,) = trade.settle();
        assertEq(w, LONG, "the rule is stated in advance, not discovered at settlement");
    }

    // ------------------------------------------------------------------
    // The three reasons money must not move
    // ------------------------------------------------------------------
    function test_no_mark_means_no_settlement() public {
        vm.warp(C + 10);
        vm.expectRevert(SettleOnMark.NoMark.selector);
        trade.settle();
    }

    function test_a_price_older_than_the_budget_is_refused() public {
        _markClose(33800000000, C - 4000, C - 60); // marked price is over an hour old
        vm.expectRevert(abi.encodeWithSelector(SettleOnMark.PriceTooOld.selector, uint64(3940)));
        trade.settle();

        (bool ok, string memory why,, uint64 age,) = trade.quote();
        assertFalse(ok);
        assertEq(why, "marked price older than the budget");
        assertEq(age, 3940);
    }

    /// The audit's case: a settlement that would have run on a day the exchange never opened.
    function test_a_mark_from_a_closed_exchange_can_never_settle() public {
        // Mark the close of a real session, then build a trade that points at a Saturday.
        SettleOnMark saturdayTrade = new SettleOnMark(
            sessionLog,
            IERC20(address(usdg)),
            address(feed),
            20260926,
            STRIKE,
            MAX_AGE,
            MARK_WINDOW,
            STAKE,
            C + 3600,
            LONG,
            SHORT
        );
        usdg.mint(LONG, STAKE);
        usdg.mint(SHORT, STAKE);
        vm.prank(LONG);
        usdg.approve(address(saturdayTrade), STAKE);
        vm.prank(SHORT);
        usdg.approve(address(saturdayTrade), STAKE);
        vm.prank(LONG);
        saturdayTrade.fund();
        vm.prank(SHORT);
        saturdayTrade.fund();

        vm.warp(1790434800); // Saturday: SessionLog refuses to record anything at all
        vm.expectRevert(SessionLog.NoSession.selector);
        sessionLog.mark(address(feed), SessionLog.Kind.CLOSE);

        vm.warp(C + 3600);
        vm.expectRevert(SettleOnMark.NoMark.selector);
        saturdayTrade.settle();
        saturdayTrade.refund();
        assertEq(usdg.balanceOf(LONG), STAKE, "the long is made whole");
        assertEq(usdg.balanceOf(SHORT), STAKE, "so is the short");
    }

    /// The mark window is five minutes wide, so whoever marks first picks a second inside it. For a
    /// settlement that is a lever, and the trade closes it: the mark must sit near the bell.
    function test_a_mark_taken_early_in_the_window_cannot_settle() public {
        _markClose(33800000000, C - 320, C - 290); // marked almost five minutes before the bell
        vm.expectRevert(abi.encodeWithSelector(SettleOnMark.MarkTooFarFromTheBell.selector, C - 290, C));
        trade.settle();

        (bool ok, string memory why,,,) = trade.quote();
        assertFalse(ok);
        assertEq(why, "mark taken too far from the bell");

        vm.warp(C + 3600);
        trade.refund();
        assertEq(usdg.balanceOf(LONG), STAKE, "an unusable mark pays nobody, it refunds");
    }

    // ------------------------------------------------------------------
    // Refund is the mirror of settlement, never a second way to pay
    // ------------------------------------------------------------------
    function test_refund_is_refused_while_the_trade_is_settleable() public {
        _markClose(33800000000, C - 120, C - 60);
        vm.warp(C + 3600);
        vm.expectRevert(SettleOnMark.StillSettleable.selector);
        trade.refund();
    }

    function test_refund_is_refused_before_the_deadline() public {
        vm.warp(C + 1);
        vm.expectRevert(SettleOnMark.TooEarly.selector);
        trade.refund();
    }

    function test_refund_returns_both_stakes_when_the_day_produced_nothing() public {
        vm.warp(C + 3600);
        trade.refund();
        assertEq(usdg.balanceOf(LONG), STAKE);
        assertEq(usdg.balanceOf(SHORT), STAKE);
        assertEq(usdg.balanceOf(address(trade)), 0);
        assertTrue(trade.closed());
    }

    function test_no_double_payout() public {
        _markClose(33800000000, C - 120, C - 60);
        trade.settle();
        vm.expectRevert(SettleOnMark.AlreadyClosed.selector);
        trade.settle();
        vm.warp(C + 7200);
        vm.expectRevert(SettleOnMark.AlreadyClosed.selector);
        trade.refund();
    }

    function test_an_unfunded_trade_cannot_settle() public {
        SettleOnMark fresh = new SettleOnMark(
            sessionLog,
            IERC20(address(usdg)),
            address(feed),
            DAY,
            STRIKE,
            MAX_AGE,
            MARK_WINDOW,
            STAKE,
            C + 3600,
            LONG,
            SHORT
        );
        _markClose(33800000000, C - 120, C - 60);
        vm.expectRevert(SettleOnMark.NotFunded.selector);
        fresh.settle();
    }

    function test_a_stranger_cannot_fund() public {
        SettleOnMark fresh = new SettleOnMark(
            sessionLog,
            IERC20(address(usdg)),
            address(feed),
            DAY,
            STRIKE,
            MAX_AGE,
            MARK_WINDOW,
            STAKE,
            C + 3600,
            LONG,
            SHORT
        );
        address stranger = address(0xDEAD);
        usdg.mint(stranger, STAKE);
        vm.startPrank(stranger);
        usdg.approve(address(fresh), STAKE);
        vm.expectRevert(SettleOnMark.NotAParty.selector);
        fresh.fund();
        vm.stopPrank();
    }
}
