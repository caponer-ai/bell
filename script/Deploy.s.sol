// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Bell, IVerifierProxy} from "../src/Bell.sol";

/// Deploys Bell against the official Chainlink Data Streams VerifierProxy.
///
/// Robinhood Chain mainnet (chainId 4663): 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7
/// (docs.robinhood.com/chain/data-streams; onchain s_feeManager = 0x0, s_accessController = 0x0, so
/// verification is free and permissionless).
///
/// Feed-to-token bindings are set once, in the constructor, and can never be changed. Deploying unbound is
/// the safe default: every check still works, only `tokenizedReference` stays 0 until a bound instance is
/// deployed with verified ERC-8056 token addresses.
///
/// Simulate:  forge script script/Deploy.s.sol --rpc-url robinhood
/// Broadcast: forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --private-key $PK
contract DeployBell is Script {
    address constant VERIFIER_PROXY_4663 = 0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7;

    function run() external returns (Bell bell) {
        address proxy = vm.envOr("VERIFIER_PROXY", VERIFIER_PROXY_4663);
        require(proxy.code.length > 0, "no verifier proxy at that address on this chain");

        bytes32[] memory feedIds = vm.envOr("FEED_IDS", ",", new bytes32[](0));
        address[] memory tokens = vm.envOr("STOCK_TOKENS", ",", new address[](0));
        require(feedIds.length == tokens.length, "FEED_IDS and STOCK_TOKENS must have the same length");

        vm.startBroadcast();
        bell = new Bell(IVerifierProxy(proxy), feedIds, tokens);
        vm.stopBroadcast();

        console.log("chainId          ", block.chainid);
        console.log("Bell             ", address(bell));
        console.log("VerifierProxy    ", proxy);
        console.log("bound feeds      ", feedIds.length);
        console.log("POLICY_VERSION   ", bell.POLICY_VERSION());
        console.log("CALENDAR_VERSION ", bell.CALENDAR_VERSION());
    }
}
