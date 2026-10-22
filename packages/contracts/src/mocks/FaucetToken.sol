// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token with a rate-limited public faucet. Localhost/testnet only, never deployed to mainnet.
contract FaucetToken is ERC20 {
    address public immutable owner;
    uint8 internal immutable _decimals;
    uint256 public immutable faucetAmount;
    uint256 public constant FAUCET_COOLDOWN = 1 days;

    mapping(address => uint256) public lastClaim;

    error NotOwner();
    error Cooldown(uint256 availableAt);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetAmount_, address owner_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
        faucetAmount = faucetAmount_;
        owner = owner_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Anyone can claim `faucetAmount` once per day.
    function faucet() external {
        uint256 next = lastClaim[msg.sender] + FAUCET_COOLDOWN;
        if (lastClaim[msg.sender] != 0 && block.timestamp < next) revert Cooldown(next);
        lastClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, faucetAmount);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        _mint(to, amount);
    }
}
