// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";

/// Robustness on REAL data: the 38 distinct DON-signed reports we hold, pushed through the REAL
/// VerifierProxy on a fork of Robinhood Chain (chainId 4663) into a real Bell, in three different orders.
/// What must not depend on the order: which observation Bell keeps as `latest`, the receipts it writes, and
/// the phase every fixing ends in.
///
/// It also pins the honest limit of this fixture set: not one of the 38 reports covers a ladder rung, so no
/// fixture can ever settle a fixing. Closing that gap needs a Data Streams subscription, not more code.
///
/// Run: forge test --fork-url robinhood --match-contract BellRobustnessFork -vv
contract BellRobustnessForkTest is Test {
    address constant PROXY = 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7;
    bytes32 constant FEED_AAPL = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant FEED_SPY = 0x000bc7e431fcd497f06b9e1dea869bcda3d05049d0601f3d1e56e64c8cdd05ac;

    /// Posting time: 5 s after the newest fixture (2026-09-09 18:00:00 UTC). Every report is then in the
    /// past, unexpired (expiresAt = obs + 30 days) and outside every posting window, so the only thing
    /// under test is order dependence.
    uint64 constant POST_AT = 1788976805;

    uint64[19] OBS = [
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

    function setUp() public {
        vm.skip(PROXY.code.length == 0);
    }

    function _load(string memory prefix, uint64 ts) internal view returns (bytes memory) {
        string memory name = string.concat("test/fixtures/reports_v11/", prefix, "_", vm.toString(uint256(ts)), ".hex");
        return vm.parseBytes(string.concat("0x", vm.readFile(name)));
    }

    /// All 38 payloads, ordered by (timestamp, feed).
    function _payloads() internal view returns (bytes[] memory out) {
        out = new bytes[](38);
        for (uint256 i = 0; i < 19; i++) {
            out[2 * i] = _load("000bbd87", OBS[i]);
            out[2 * i + 1] = _load("000bc7e4", OBS[i]);
        }
    }

    function _newBell() internal returns (Bell) {
        return new Bell(IVerifierProxy(PROXY), new bytes32[](0), new address[](0));
    }

    struct Snapshot {
        int192 aaplMid;
        uint32 aaplObs;
        int192 spyMid;
        uint32 spyObs;
        uint8 phaseOpen0908;
        uint8 phaseClose0908;
        uint8 phaseOpen0909;
        uint256 evidenceCount; // receipts that counted as evidence for some fixing
    }

    /// Posts the payloads in the given order into a fresh Bell and snapshots everything a consumer can read.
    function _postAll(uint256[] memory order) internal returns (Snapshot memory s) {
        Bell bell = _newBell();
        bytes[] memory p = _payloads();
        vm.warp(POST_AT);
        for (uint256 k = 0; k < order.length; k++) {
            bytes32 id = bell.post(p[order[k]]);
            if (bell.receipt(id).phase != 0) s.evidenceCount++;
        }
        (s.aaplMid,,, s.aaplObs,,,,,) = bell.latest(FEED_AAPL);
        (s.spyMid,,, s.spyObs,,,,,) = bell.latest(FEED_SPY);
        s.phaseOpen0908 = uint8(bell.openPhase(FEED_AAPL, 20260908));
        s.phaseClose0908 = uint8(bell.closePhase(FEED_AAPL, 20260908));
        s.phaseOpen0909 = uint8(bell.openPhase(FEED_AAPL, 20260909));
    }

    function _forward() internal pure returns (uint256[] memory o) {
        o = new uint256[](38);
        for (uint256 i = 0; i < 38; i++) {
            o[i] = i;
        }
    }

    function _reverse() internal pure returns (uint256[] memory o) {
        o = new uint256[](38);
        for (uint256 i = 0; i < 38; i++) {
            o[i] = 37 - i;
        }
    }

    /// Interleaved: all SPY reports first, then all AAPL, each feed newest to oldest.
    function _interleaved() internal pure returns (uint256[] memory o) {
        o = new uint256[](38);
        uint256 k;
        for (uint256 i = 19; i > 0; i--) {
            o[k++] = 2 * (i - 1) + 1;
        }
        for (uint256 i = 19; i > 0; i--) {
            o[k++] = 2 * (i - 1);
        }
        return o;
    }

    /// Three orders of the same 38 signed reports must leave Bell in the same readable state.
    function test_order_of_real_reports_does_not_change_state() public {
        Snapshot memory a = _postAll(_forward());
        Snapshot memory b = _postAll(_reverse());
        Snapshot memory c = _postAll(_interleaved());

        assertEq(a.aaplObs, 1788976800, "AAPL latest must be the newest observation");
        assertEq(b.aaplObs, a.aaplObs, "reverse order changed AAPL latest");
        assertEq(c.aaplObs, a.aaplObs, "interleaved order changed AAPL latest");
        assertEq(b.aaplMid, a.aaplMid, "reverse order changed AAPL mid");
        assertEq(c.aaplMid, a.aaplMid, "interleaved order changed AAPL mid");

        assertEq(b.spyObs, a.spyObs, "reverse order changed SPY latest");
        assertEq(c.spyObs, a.spyObs, "interleaved order changed SPY latest");
        assertEq(b.spyMid, a.spyMid, "reverse order changed SPY mid");
        assertEq(c.spyMid, a.spyMid, "interleaved order changed SPY mid");

        assertEq(b.phaseOpen0908, a.phaseOpen0908, "reverse order changed the 08.09 open phase");
        assertEq(c.phaseOpen0908, a.phaseOpen0908, "interleaved order changed the 08.09 open phase");
        assertEq(b.phaseClose0908, a.phaseClose0908, "reverse order changed the 08.09 close phase");
        assertEq(b.phaseOpen0909, a.phaseOpen0909, "reverse order changed the 09.09 open phase");

        emit log_named_decimal_int("AAPL latest mid", a.aaplMid, 18);
        emit log_named_decimal_int("SPY latest mid", a.spyMid, 18);
    }

    /// The limit, stated as an assertion: none of the 38 real reports is evidence for any fixing, so both
    /// trading days end UNRESOLVED no matter what we post. This is what a paid stream changes.
    function test_no_real_fixture_is_evidence_for_a_fixing() public {
        Snapshot memory a = _postAll(_forward());
        assertEq(a.evidenceCount, 0, "a fixture counted as evidence: the ladder assumption changed");
        assertEq(a.phaseOpen0908, uint8(Bell.Phase.OPEN_UNRESOLVED), "08.09 open");
        assertEq(a.phaseClose0908, uint8(Bell.Phase.CLOSE_UNRESOLVED), "08.09 close");
        assertEq(a.phaseOpen0909, uint8(Bell.Phase.OPEN_UNRESOLVED), "09.09 open");
    }
}
