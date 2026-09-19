// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Test double of Chainlink's VerifierProxy: returns reportData as-is without
///         checking signatures (same behaviour as Chainlink Local's MockVerifierProxy).
///         Signature checks are covered by test/VerifyFixture.t.sol on a mainnet fork.
contract MockVerifierProxy {
    mapping(bytes32 => address) public verifiers;
    bool public rejectAll;

    function setVerifier(bytes32 digest, address v) external {
        verifiers[digest] = v;
    }

    function setRejectAll(bool r) external {
        rejectAll = r;
    }

    function verify(bytes calldata payload, bytes calldata) external payable returns (bytes memory) {
        if (rejectAll) revert("mock: verification failed");
        (, bytes memory reportData,,,) = abi.decode(payload, (bytes32[3], bytes, bytes32[], bytes32[], bytes32));
        return reportData;
    }

    function getVerifier(bytes32 configDigest) external view returns (address) {
        return verifiers[configDigest];
    }
}
