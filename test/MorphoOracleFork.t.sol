// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PushFeedGuard} from "../src/PushFeedGuard.sol";

interface IMorphoOracle {
    function price() external view returns (uint256);
}

/// What a live lending market on this chain sees at the weekend, next to what the guard says.
///
/// The oracle below prices NVDA collateral for a real Morpho Blue market on chainId 4663 (market id
/// 0x8b16891f…9c3e, loan token USDG, LLTV 62.5 %). Its bytecode carries a maximum base-feed age of 97 hours,
/// which is a deliberate choice: an equity oracle that refused anything older than a day would freeze the
/// market every weekend. The cost of that choice is that from Friday's close to the first print of the next
/// session the oracle returns a number with nothing attached to say the market behind it is shut.
///
/// Nothing is mocked. The test forks mainnet and asks both contracts the same question at the fork's own
/// block time, then once more just past the oracle's 97 hour ceiling. It does not warp to a future weekend:
/// a fork receives no new rounds, so a warped Saturday would show a price frozen since the fork was taken,
/// which is an artifact of the fork, not of the market. The oracle's address is immutable in the market, so this is evidence of the
/// gap, not an integration: fixing it means a new market with a session-aware oracle, or a consumer that
/// reads the guard before acting.
///
///     forge test --fork-url robinhood --match-path "test/MorphoOracleFork.t.sol" -vv
contract MorphoOracleForkTest is Test {
    PushFeedGuard constant GUARD = PushFeedGuard(0x8aF68a9fF7583097A7476060C6B56eB33dA7a711);
    IMorphoOracle constant NVDA_ORACLE = IMorphoOracle(0xED29D310cfa91778A5850538DA28ed42234Cb78c);
    address constant NVDA_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    function setUp() public {
        vm.skip(address(NVDA_ORACLE).code.length == 0 || address(GUARD).code.length == 0);
    }

    function _ask(string memory when, uint64 at) internal returns (bool oracleAnswers) {
        vm.warp(at);
        (, int256 answer,, uint256 updatedAt,) = IFeed(NVDA_FEED).latestRoundData();
        (PushFeedGuard.Verdict v, PushFeedGuard.Reason r,,) = GUARD.check(NVDA_FEED, 900);
        uint8 verdict = uint8(v);
        uint8 reason = uint8(r);
        uint256 p;
        try NVDA_ORACLE.price() returns (uint256 px) {
            p = px;
            oracleAnswers = true;
        } catch {}
        console.log("---", when);
        console.log("  feed answer (8 dp)      ", uint256(answer));
        console.log("  feed age, hours         ", (at - updatedAt) / 3600);
        console.log("  Morpho oracle answers   ", oracleAnswers);
        console.log("  Morpho oracle price()   ", p);
        console.log("  guard verdict / reason  ", verdict, reason);
    }

    function test_the_market_prices_a_shut_exchange_without_saying_so() public {
        (,,, uint256 updatedAt,) = IFeed(NVDA_FEED).latestRoundData();

        // The fork's own block time first: whenever this runs outside the session with the last print younger
        // than 97 hours, the oracle answers and the guard refuses. That is the gap, live.
        uint64 nowTs = uint64(block.timestamp);
        bool answersNow = _ask("fork block time (as run)", nowTs);
        (PushFeedGuard.Verdict vn,,,) = GUARD.check(NVDA_FEED, 900);
        if (vn == PushFeedGuard.Verdict.REJECT && nowTs - updatedAt <= 97 hours) {
            assertTrue(answersNow, "outside the session, under 97h: the oracle answers while the guard refuses");
        }

        // Past the oracle's own ceiling it stops answering at all: the market freezes rather than knowing why.
        bool late = _ask("97 hours after the last print (the oracle's ceiling)", uint64(updatedAt + 97 hours + 1));
        assertFalse(late, "past 97h the oracle should refuse");
    }
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}
