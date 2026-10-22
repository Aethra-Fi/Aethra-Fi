// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3, IMarketSession} from "../interfaces/IOracle.sol";

/// @notice Owner-pushed price feed for localhost/testnet (stock tokens have no testnet oracle).
contract MockPriceFeed is IAggregatorV3, IMarketSession {
    address public immutable owner;
    uint8 public immutable decimals;
    string public description;

    int256 internal _answer;
    uint256 internal _updatedAt;
    uint80 internal _round;
    bool public isMarketOpen = true;

    event PriceUpdated(int256 answer, uint256 updatedAt, bool marketOpen);

    error NotOwner();

    constructor(address owner_, uint8 decimals_, string memory description_, int256 initialAnswer) {
        owner = owner_;
        decimals = decimals_;
        description = description_;
        _set(initialAnswer, true);
    }

    function setPrice(int256 answer) external {
        if (msg.sender != owner) revert NotOwner();
        _set(answer, isMarketOpen);
    }

    function setPriceAndSession(int256 answer, bool marketOpen) external {
        if (msg.sender != owner) revert NotOwner();
        _set(answer, marketOpen);
    }

    function _set(int256 answer, bool marketOpen) internal {
        _answer = answer;
        _updatedAt = block.timestamp;
        isMarketOpen = marketOpen;
        unchecked {
            ++_round;
        }
        emit PriceUpdated(answer, block.timestamp, marketOpen);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (_round, _answer, _updatedAt, _updatedAt, _round);
    }
}
