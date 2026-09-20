// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";
import {SettleMini, IBell, IERC20} from "../src/SettleMini.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

/// USDG stand-in: 6 decimals, like Paxos USDG at 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 on chain 4663.
contract USDG {
    uint8 public constant decimals = 6;
    string public constant symbol = "USDG";

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// The demo consumer, end to end: two parties, real USDG movements, and a payout that exists only when
/// Bell's ladder is FINAL. Day 2026-09-09 (EDT): O = 13:30:00 UTC, C = 20:00:00 UTC.
contract SettleMiniTest is Test {
    MockVerifierProxy proxy;
    Bell bell;
    USDG usdg;
    SettleMini trade;

    bytes32 constant FEED = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant DIGEST = 0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee;
    uint32 constant DAY = 20260909;
    uint64 constant O = 1788960600;
    uint64 constant R = 30;
    uint64 constant WINDOW = 300;
    uint64 constant NS = 1e9;

    uint256 constant STAKE = 500e6; // 500 USDG a side
    int192 constant STRIKE = 316e18; // 316.00

    address constant LONG = address(0xA11CE);
    address constant SHORT = address(0xB0B);

    function setUp() public {
        proxy = new MockVerifierProxy();
        bell = new Bell(IVerifierProxy(address(proxy)), new bytes32[](0), new address[](0));
        usdg = new USDG();
        trade = new SettleMini(
            IBell(address(bell)),
            IERC20(address(usdg)),
            FEED,
            DAY,
            false,
            STRIKE,
            STAKE,
            O + 2 * WINDOW, // refunds open after the fixing is immutable
            LONG,
            SHORT
        );
        usdg.mint(LONG, STAKE);
        usdg.mint(SHORT, STAKE);
        vm.prank(LONG);
        usdg.approve(address(trade), STAKE);
        vm.prank(SHORT);
        usdg.approve(address(trade), STAKE);
        vm.warp(O - 3600);
        vm.prank(LONG);
        trade.fund();
        vm.prank(SHORT);
        trade.fund();
    }

    function _rep(uint64 obs, int192 mid, uint32 status, uint64 seenNs) internal pure returns (bytes memory) {
        bytes memory reportData = abi.encode(
            FEED,
            uint32(obs),
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

    /// Rung 0 proven out by a pre-bell mid (the realistic case), rung 1 carries the reference.
    function _resolveAt(int192 mid) internal {
        vm.warp(O + 1);
        bell.post(_rep(O, 315e18, 2, O * NS - 3_264_000_000));
        vm.warp(O + R + 1);
        bell.post(_rep(O + R, mid, 2, (O + R) * NS));
        vm.warp(O + WINDOW + 1);
    }

    function test_money_moves_to_the_long_when_the_reference_clears_the_strike() public {
        _resolveAt(317e18);
        (, uint8 reasonBefore, int192 refBefore, address winnerBefore) = trade.quote();
        assertEq(refBefore, 317e18, "quote shows the reference");
        assertEq(winnerBefore, LONG, "quote names the winner");
        assertEq(reasonBefore, 0, "reason OK");

        (address winner, int192 referencePrice) = trade.settle();
        assertEq(winner, LONG);
        assertEq(referencePrice, 317e18);
        assertEq(usdg.balanceOf(LONG), 2 * STAKE, "long holds both stakes");
        assertEq(usdg.balanceOf(SHORT), 0);
        assertEq(usdg.balanceOf(address(trade)), 0, "escrow empty");
        assertTrue(trade.closed());
    }

    function test_money_moves_to_the_short_when_the_reference_misses_the_strike() public {
        _resolveAt(315e18);
        (address winner,) = trade.settle();
        assertEq(winner, SHORT);
        assertEq(usdg.balanceOf(SHORT), 2 * STAKE);
    }

    /// Exactly at the strike the long wins: the rule is stated, not discovered at settlement time.
    function test_reference_exactly_at_strike_pays_the_long() public {
        _resolveAt(STRIKE);
        (address winner,) = trade.settle();
        assertEq(winner, LONG);
    }

    function test_cannot_settle_while_the_fixing_is_pending() public {
        vm.warp(O + 1);
        bell.post(_rep(O, 315e18, 2, O * NS - 3_264_000_000));
        vm.warp(O + R + 1);
        bell.post(_rep(O + R, 317e18, 2, (O + R) * NS));
        // still inside the posting window: Bell answers WAIT / REFERENCE_PENDING
        vm.expectRevert(abi.encodeWithSelector(SettleMini.NotSettleable.selector, uint8(8)));
        trade.settle();
    }

    /// The withholding case: rung 0 never posted, the session never resolves, both stakes go home.
    function test_unresolved_session_refunds_both_sides() public {
        vm.warp(O + R + 1);
        bell.post(_rep(O + R, 317e18, 2, (O + R) * NS)); // rung 1 only
        vm.warp(O + WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(SettleMini.NotSettleable.selector, uint8(9))); // REFERENCE_UNRESOLVED
        trade.settle();

        vm.expectRevert(SettleMini.TooEarly.selector);
        trade.refund();

        vm.warp(O + 2 * WINDOW);
        trade.refund();
        assertEq(usdg.balanceOf(LONG), STAKE, "long got its stake back");
        assertEq(usdg.balanceOf(SHORT), STAKE, "short got its stake back");
        assertEq(usdg.balanceOf(address(trade)), 0);
    }

    /// A resolvable session cannot be refunded: refund is the escape hatch, not a second payout path.
    function test_refund_refuses_when_the_session_did_resolve() public {
        _resolveAt(317e18);
        vm.warp(O + 2 * WINDOW);
        vm.expectRevert(abi.encodeWithSelector(SettleMini.NotSettleable.selector, uint8(0)));
        trade.refund();
    }

    function test_no_double_settlement() public {
        _resolveAt(317e18);
        trade.settle();
        vm.expectRevert(SettleMini.AlreadyClosed.selector);
        trade.settle();
        vm.expectRevert(SettleMini.AlreadyClosed.selector);
        trade.refund();
    }

    function test_only_the_two_parties_can_fund() public {
        SettleMini fresh = new SettleMini(
            IBell(address(bell)), IERC20(address(usdg)), FEED, DAY, false, STRIKE, STAKE, O + 2 * WINDOW, LONG, SHORT
        );
        address stranger = address(0xDEAD);
        usdg.mint(stranger, STAKE);
        vm.startPrank(stranger);
        usdg.approve(address(fresh), STAKE);
        vm.expectRevert(SettleMini.NotAParty.selector);
        fresh.fund();
        vm.stopPrank();
    }

    function test_settlement_event_carries_the_receipt_of_the_report_that_paid() public {
        _resolveAt(317e18);
        (,, bytes32 receiptIdFromBell) = _reference();
        vm.recordLogs();
        trade.settle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Settled(address,int192,bytes32,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (, bytes32 receiptId,) = abi.decode(logs[i].data, (int192, bytes32, uint256));
                assertEq(receiptId, receiptIdFromBell, "event must name the DON report behind the price");
                found = true;
            }
        }
        assertTrue(found, "Settled event");
    }

    function _reference() internal view returns (int192 mid, uint8 reason, bytes32 receiptId) {
        (Bell.Verdict v, Bell.Reason r, int192 m, bytes32 id) = bell.checkSettle(FEED, DAY, false);
        v; // silence
        return (m, uint8(r), id);
    }
}
