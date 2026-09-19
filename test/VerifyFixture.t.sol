// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// Chainlink Data Streams VerifierProxy (docs.robinhood.com/chain/data-streams).
interface IVerifierProxy {
    function verify(bytes calldata payload, bytes calldata parameterPayload)
        external
        payable
        returns (bytes memory verifierResponse);
}

/// Integration test against the REAL VerifierProxy on Robinhood Chain (chainId 4663),
/// using REAL DON-signed v11 reports extracted from mainnet calldata
/// (see script/extract_reports.py). No Data Streams subscription needed.
///
/// Run: forge test --fork-url robinhood --match-contract VerifyFixture -vv
contract VerifyFixtureTest is Test {
    IVerifierProxy constant PROXY = IVerifierProxy(0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7);
    bytes32 constant FEED_AAPL = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant FEED_SPY = 0x000bc7e431fcd497f06b9e1dea869bcda3d05049d0601f3d1e56e64c8cdd05ac;

    struct ReportV11 {
        bytes32 feedId;
        uint32 validFromTimestamp;
        uint32 observationsTimestamp;
        uint192 nativeFee;
        uint192 linkFee;
        uint32 expiresAt;
        int192 mid;
        uint64 lastSeenTimestampNs;
        int192 bid;
        int192 bidVolume;
        int192 ask;
        int192 askVolume;
        int192 lastTradedPrice;
        uint32 marketStatus;
    }

    /// These tests need the real proxy: skip when not running on a fork of Robinhood Chain.
    function setUp() public {
        vm.skip(address(PROXY).code.length == 0);
    }

    function _load(string memory name) internal view returns (bytes memory) {
        string memory hexStr = vm.readFile(string.concat("test/fixtures/reports_v11/", name));
        return vm.parseBytes(string.concat("0x", hexStr));
    }

    function _decode(bytes memory verified) internal pure returns (ReportV11 memory r) {
        r = abi.decode(verified, (ReportV11));
    }

    /// Real AAPL report observed 2026-09-08 16:00:00 UTC (1788883200), verified through the real proxy.
    function test_verifyRealAaplReport() public {
        bytes memory payload = _load("000bbd87_1788883200.hex");
        bytes memory verified = PROXY.verify(payload, "");
        ReportV11 memory r = _decode(verified);

        assertEq(r.feedId, FEED_AAPL, "feedId");
        assertEq(r.observationsTimestamp, 1788883200, "obs 2026-09-08 16:00:00 UTC");
        assertEq(r.marketStatus, 2, "regular session");
        assertGt(r.mid, 0, "mid > 0");
        assertGt(r.expiresAt, r.observationsTimestamp, "expiresAt after obs");
        emit log_named_decimal_int("mid", r.mid, 18);
        emit log_named_decimal_int("bid", r.bid, 18);
        emit log_named_decimal_int("ask", r.ask, 18);
        emit log_named_uint("expiresAt", r.expiresAt);
        emit log_named_uint("lastSeenTimestampNs", r.lastSeenTimestampNs);
    }

    /// Real SPY report at the same timestamp.
    function test_verifyRealSpyReport() public {
        ReportV11 memory r = _decode(PROXY.verify(_load("000bc7e4_1788883200.hex"), ""));
        assertEq(r.feedId, FEED_SPY, "feedId");
        assertEq(r.marketStatus, 2, "regular session");
        emit log_named_decimal_int("SPY mid", r.mid, 18);
    }

    /// Replay: the same signed report verifies twice. The proxy does not stop replays;
    /// that duty is the consumer's (Bell enforces receipts + monotonic observationsTimestamp).
    function test_replayIsAcceptedByProxy() public {
        bytes memory payload = _load("000bbd87_1788883200.hex");
        bytes memory a = PROXY.verify(payload, "");
        bytes memory b = PROXY.verify(payload, "");
        assertEq(keccak256(a), keccak256(b), "identical verified bytes on replay");
    }

    /// A tampered payload (one byte of the report flipped) must be rejected by the DON signature check.
    function test_tamperedReportReverts() public {
        bytes memory payload = _load("000bbd87_1788883200.hex");
        // reportContext occupies the first 3 words; word 4 is the offset of reportData.
        // Flip a byte deep inside reportData (mid field area) to break the signature.
        uint256 idx = 32 * 3 + 32 + 32 + 32 * 6 + 31;
        payload[idx] = bytes1(uint8(payload[idx]) ^ 0x01);
        vm.expectRevert();
        PROXY.verify(payload, "");
    }
}
