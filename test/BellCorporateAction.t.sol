// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";
import {MockVerifierProxy} from "./mocks/MockVerifierProxy.sol";

/// Mock of a Robinhood ERC-8056 stock token: uiMultiplier + oraclePaused.
contract MockStockToken {
    uint256 public uiMultiplier = 1e18;
    bool public oraclePaused;

    function setMultiplier(uint256 m) external {
        uiMultiplier = m;
    }

    function setPaused(bool p) external {
        oraclePaused = p;
    }
}

/// Round-5 critique (first reviewer), section H: Bell must not mix two corporate-action epochs, and must honour the
/// issuer's oraclePaused() flag. Day: 2026-09-09 (EDT), O = 13:30:00 UTC; reports sit on ladder rung 0 (obs == O).
contract BellCorporateActionTest is Test {
    MockVerifierProxy proxy;
    MockStockToken token;
    Bell bell;

    bytes32 constant FEED = 0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1;
    bytes32 constant DIGEST = 0x00094baebfda9b87680d8e59aa20a3e565126640ee7caeab3cd965e5568b17ee;
    uint32 constant DAY = 20260909;
    uint64 constant O = 1788960600;
    uint64 constant NS = 1e9;

    function setUp() public {
        proxy = new MockVerifierProxy();
        token = new MockStockToken();
        bytes32[] memory feeds = new bytes32[](1);
        address[] memory tokens = new address[](1);
        feeds[0] = FEED;
        tokens[0] = address(token);
        bell = new Bell(IVerifierProxy(address(proxy)), feeds, tokens);
    }

    function _payload(uint64 obs, int192 mid, uint32 status) internal pure returns (bytes memory) {
        bytes memory reportData = abi.encode(
            FEED,
            uint32(obs),
            uint32(obs),
            uint192(0),
            uint192(0),
            uint32(obs + 30 days),
            mid,
            uint64(obs * NS),
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

    /// Split 2:1 after the reference was fixed: settlement must use the multiplier of the fixing moment.
    function test_multiplier_snapshot_survives_split() public {
        vm.warp(O + 2);
        bell.post(_payload(O, 316e18, 2));
        token.setMultiplier(2e18); // corporate action later in the day
        vm.warp(O + 300);
        uint256 ref = bell.tokenizedReference(FEED, DAY, false);
        assertEq(ref, 316e18, "reference keeps the 1.0 multiplier of the fixing moment");
        assertEq(
            bell.receipt(keccak256(_payload(O, 316e18, 2))).multiplier,
            1e18,
            "receipt records the multiplier at acceptance"
        );
    }

    /// A report accepted after the split snapshots the new multiplier.
    function test_multiplier_snapshot_after_split() public {
        token.setMultiplier(2e18);
        vm.warp(O + 2);
        bell.post(_payload(O, 158e18, 2)); // mid already in the post-split base
        vm.warp(O + 300);
        assertEq(bell.tokenizedReference(FEED, DAY, false), 316e18, "158 x 2.0");
    }

    /// Issuer pause: no ALLOW while oraclePaused() is true, for LIVE and for SETTLE.
    function test_oraclePaused_blocks_allow() public {
        vm.warp(O + 2);
        bell.post(_payload(O, 316e18, 2));
        token.setPaused(true);
        (Bell.Verdict v, Bell.Reason why) = bell.checkLive(FEED);
        assertEq(uint256(v), uint256(Bell.Verdict.REJECT));
        assertEq(uint256(why), uint256(Bell.Reason.CA_PAUSED));
        vm.warp(O + 300);
        (v, why,,) = bell.checkSettle(FEED, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.REJECT));
        assertEq(uint256(why), uint256(Bell.Reason.CA_PAUSED));
        token.setPaused(false);
        (v, why,,) = bell.checkSettle(FEED, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.ALLOW));
    }

    /// Unbound feed: multiplier 0, tokenizedReference 0, raw reference still available.
    function test_unbound_feed_has_no_tokenized_reference() public {
        bytes32 other = 0x000bc7e431fcd497f06b9e1dea869bcda3d05049d0601f3d1e56e64c8cdd05ac;
        bytes memory reportData = abi.encode(
            other,
            uint32(O),
            uint32(O),
            uint192(0),
            uint192(0),
            uint32(O + 30 days),
            int192(760e18),
            uint64(O * NS),
            int192(759e18),
            int192(1e18),
            int192(761e18),
            int192(1e18),
            int192(760e18),
            uint32(2)
        );
        bytes32[3] memory ctx = [DIGEST, bytes32(uint256(1)), bytes32(0)];
        vm.warp(O + 2);
        bell.post(abi.encode(ctx, reportData, new bytes32[](1), new bytes32[](1), bytes32(0)));
        vm.warp(O + 300);
        assertEq(bell.tokenizedReference(other, DAY, false), 0);
        (Bell.Verdict v,, int192 mid,) = bell.checkSettle(other, DAY, false);
        assertEq(uint256(v), uint256(Bell.Verdict.ALLOW));
        assertEq(mid, 760e18);
    }
}
