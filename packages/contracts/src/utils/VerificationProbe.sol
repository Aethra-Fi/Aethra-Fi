// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal contract deployed once on a network to prove, before a release, that its explorer shows source
///         code verified through Sourcify (scripts/mainnet-verify-probe.sh). Holds no funds and has no logic.
contract VerificationProbe {
    string public constant NAME = "Aethra Fi verification probe";
    address public immutable deployer;

    constructor() {
        deployer = msg.sender;
    }
}
