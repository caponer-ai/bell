// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";
import {BellFeedAdapter} from "../src/BellFeedAdapter.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

/// A consumer written the way the contracts already on this chain are written: it calls
/// latestRoundData() and compares two snapshots. Nothing about it knows that Bell exists.
interface IPriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract NaiveMarket {
    IPriceFeed public immutable FEED;
    int256 public openPrice;
    int256 public closePrice;
    bool public locked;
    bool public settled;

    constructor(IPriceFeed feed) {
        FEED = feed;
    }

    function lock() external {
        (, int256 p,,,) = FEED.latestRoundData();
        openPrice = p;
        locked = true;
    }

    function settle() external returns (bool bullWins) {
        (, int256 p,,,) = FEED.latestRoundData();
        closePrice = p;
        settled = true;
        return p >= openPrice; // the tie rule the audit found in the live market
    }
}

/// The adapter is the whole integration story: an existing consumer changes one address and starts
/// refusing the settlements it used to resolve silently. Day 2026-09-09 (EDT), O = 13:30:00 UTC.
contract BellFeedAdapterTest is Test {
    MockVerifierProxy proxy;
    Bell bell;
    BellFeedAdapter adapter;
    NaiveMarket market;

    bytes32 constant FEED = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant DIGEST = 0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee;
    uint32 constant DAY = 20260909;
    uint64 constant O = 1788960600;
    uint64 constant C = 1788984000;
    uint64 constant R = 30;
    uint64 constant WINDOW = 300;
    uint64 constant NS = 1e9;

    function setUp() public {
        proxy = new MockVerifierProxy();
        bell = new Bell(IVerifierProxy(address(proxy)), new bytes32[](0), new address[](0));
        adapter = new BellFeedAdapter(bell, FEED, "Bell-vetted AAPL / USD (session aware)");
        market = new NaiveMarket(IPriceFeed(address(adapter)));
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

    function _postFresh(uint64 at, int192 mid) internal {
        vm.warp(at);
        bell.post(_rep(at, mid, 2, at * NS));
    }

    // ------------------------------------------------------------------
    // Units: 18 decimals in Bell, 8 out, because that is what the push feeds on this chain report
    // ------------------------------------------------------------------
    function test_price_is_scaled_to_eight_decimals() public {
        _postFresh(O + 60, 313.25735e18);
        (, int256 answer,, uint256 updatedAt,) = adapter.latestRoundData();
        assertEq(answer, 31325735000, "313.25735 with 8 decimals");
        assertEq(adapter.decimals(), 8);
        assertEq(updatedAt, O + 60, "updatedAt is the observation second, not a round counter");
    }

    // ------------------------------------------------------------------
    // The one behavioural change: a call that cannot be answered honestly reverts
    // ------------------------------------------------------------------
    function test_reverts_when_the_observation_is_stale() public {
        _postFresh(O + 60, 313e18);
        vm.warp(O + 60 + 31); // MAX_OBS_AGE is 30 s
        vm.expectRevert(abi.encodeWithSelector(BellFeedAdapter.NotAdmissible.selector, uint8(3))); // OBS_STALE
        adapter.latestRoundData();
    }

    /// Five seconds after the closing bell the observation is still fresh by every staleness bound.
    /// What refuses the call is the calendar, which is the answer no push feed can give.
    function test_reverts_after_the_closing_bell_even_with_a_fresh_observation() public {
        _postFresh(C - 10, 313e18);
        vm.warp(C + 5);
        assertEq(uint256(C + 5) - (C - 10), 15, "observation is 15 s old: well inside every freshness bound");
        vm.expectRevert(abi.encodeWithSelector(BellFeedAdapter.NotAdmissible.selector, uint8(7))); // OUTSIDE_SESSION
        adapter.latestRoundData();
    }

    /// The weekend case, which is where the audited settlements lived.
    function test_reverts_on_a_weekend() public {
        uint64 saturday = 1789300000; // 2026-09-12, no session at all
        vm.warp(saturday);
        bell.post(_rep(saturday, 313e18, 2, saturday * NS));
        (bool ok, uint8 reason,,) = adapter.tryLatestRoundData();
        assertFalse(ok);
        assertEq(reason, 10, "NO_SESSION: the calendar knows there is no trading day");
    }

    function test_reverts_when_the_don_says_the_market_is_not_regular() public {
        vm.warp(O + 60);
        bell.post(_rep(O + 60, 313e18, 4, (O + 60) * NS)); // overnight
        vm.expectRevert(abi.encodeWithSelector(BellFeedAdapter.NotAdmissible.selector, uint8(6))); // NON_REGULAR
        adapter.latestRoundData();
    }

    function test_reverts_when_nothing_was_ever_posted() public {
        vm.warp(O + 60);
        vm.expectRevert(abi.encodeWithSelector(BellFeedAdapter.NotAdmissible.selector, uint8(1))); // NO_DATA
        adapter.latestRoundData();
    }

    function test_try_variant_reports_the_reason_instead_of_reverting() public {
        vm.warp(O + 60);
        (bool ok, uint8 reason, int256 answer,) = adapter.tryLatestRoundData();
        assertFalse(ok);
        assertEq(reason, 1, "NO_DATA");
        assertEq(answer, 0);

        _postFresh(O + 90, 314e18);
        (ok, reason, answer,) = adapter.tryLatestRoundData();
        assertTrue(ok);
        assertEq(reason, 0);
        assertEq(answer, 31400000000);
    }

    // ------------------------------------------------------------------
    // The audit, replayed as a test: the same naive market, one address different
    // ------------------------------------------------------------------
    function test_a_naive_market_settled_on_a_closed_exchange_now_reverts() public {
        // Saturday 2026-09-12, the pattern of 28 of the 30 settlements we audited
        uint64 saturday = 1789300000;
        vm.warp(O + 60);
        bell.post(_rep(O + 60, 313e18, 2, (O + 60) * NS)); // a perfectly good in-session report

        vm.warp(saturday);
        vm.expectRevert(abi.encodeWithSelector(BellFeedAdapter.NotAdmissible.selector, uint8(3)));
        market.lock();
        assertFalse(market.locked(), "the market cannot even lock on a price from another day");
    }

    function test_a_naive_market_works_normally_inside_the_session() public {
        _postFresh(O + 60, 313e18);
        market.lock();
        assertEq(market.openPrice(), 31300000000);

        _postFresh(O + 120, 315e18);
        bool bull = market.settle();
        assertTrue(bull, "price moved up");
        assertEq(market.closePrice(), 31500000000);
    }

    /// The tie the audit found: with Bell, two reads seconds apart cannot silently return one number,
    /// because a second read needs a second admissible observation.
    function test_two_reads_seconds_apart_need_two_admissible_observations() public {
        _postFresh(O + 60, 313e18);
        market.lock();
        vm.warp(O + 60 + 31);
        vm.expectRevert(abi.encodeWithSelector(BellFeedAdapter.NotAdmissible.selector, uint8(3)));
        market.settle();
        assertFalse(market.settled());
    }

    // ------------------------------------------------------------------
    // Settlement reference through the same adapter
    // ------------------------------------------------------------------
    function test_session_reference_is_served_only_when_final() public {
        vm.warp(O + 1);
        bell.post(_rep(O, 315e18, 2, O * NS - 3_264_000_000)); // rung 0 proven out
        vm.warp(O + R + 1);
        bell.post(_rep(O + R, 316e18, 2, (O + R) * NS)); // rung 1 candidate

        vm.expectRevert(abi.encodeWithSelector(BellFeedAdapter.NotAdmissible.selector, uint8(8))); // PENDING
        adapter.sessionReference(DAY, false);

        vm.warp(O + WINDOW + 1);
        (int256 answer, uint256 observedAt, bytes32 receiptId) = adapter.sessionReference(DAY, false);
        assertEq(answer, 31600000000, "316.00 with 8 decimals");
        assertEq(observedAt, O + R);
        assertTrue(receiptId != bytes32(0), "the receipt of the report that set the reference");
    }

    function test_historical_rounds_are_refused_loudly() public {
        vm.expectRevert(BellFeedAdapter.HistoricalRoundsNotSupported.selector);
        adapter.getRoundData(1);
    }
}
