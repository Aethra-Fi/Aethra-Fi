// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title LaunchToken
/// @notice Minimal fixed-supply ERC20 deployed by the launchpad as EIP-1167 clones of one implementation.
///         The whole supply is minted to the launchpad on initialization. Not upgradeable, no owner.
contract LaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    error AlreadyInitialized();
    error ZeroLaunchpad();

    /// @notice Launchpad that received the supply (address(0) until initialized).
    address public launchpad;
    string private _name;
    string private _symbol;

    constructor() {
        // Lock the implementation itself; clones start with empty storage.
        launchpad = address(0xdead);
    }

    /// @dev Called by the launchpad in the same transaction that creates the clone.
    function initialize(string calldata name_, string calldata symbol_, address launchpad_) external {
        if (launchpad != address(0)) revert AlreadyInitialized();
        if (launchpad_ == address(0)) revert ZeroLaunchpad();
        launchpad = launchpad_;
        _name = name_;
        _symbol = symbol_;
        _mint(launchpad_, TOTAL_SUPPLY);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}
