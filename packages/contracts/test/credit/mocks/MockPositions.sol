// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IAethraPositions} from "../../../src/interfaces/IAethraPeriphery.sol";
import {MockToken} from "./MockToken.sol";

/// @notice Minimal stand-in for AethraPositions: settable amounts and fees, `collect` mints the fee tokens.
///         Only the surface the CreditManager uses is meaningful.
contract MockPositions is ERC721 {
    mapping(uint256 => IAethraPositions.Position) internal _pos;
    mapping(uint256 => uint256[2]) internal _amounts;
    mapping(uint256 => uint256[2]) internal _fees;
    uint256 public nextTokenId = 1;

    event FeesCollected(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    constructor() ERC721("Mock Positions", "MPOS") {}

    function mintPosition(address to, PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        returns (uint256 tokenId)
    {
        tokenId = nextTokenId++;
        _pos[tokenId] = IAethraPositions.Position(key, -600, 600, 1e18);
        _amounts[tokenId] = [amount0, amount1];
        _mint(to, tokenId);
    }

    function setAmounts(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        _amounts[tokenId] = [amount0, amount1];
    }

    function setFees(uint256 tokenId, uint256 fee0, uint256 fee1) external {
        _fees[tokenId] = [fee0, fee1];
    }

    function getPosition(uint256 tokenId) external view returns (IAethraPositions.Position memory) {
        return _pos[tokenId];
    }

    function positionAmounts(uint256 tokenId) external view returns (uint256, uint256) {
        return (_amounts[tokenId][0], _amounts[tokenId][1]);
    }

    function collect(uint256 tokenId, address recipient) external returns (uint256 fee0, uint256 fee1) {
        require(_isAuthorized(ownerOf(tokenId), msg.sender, tokenId), "not owner");
        (fee0, fee1) = (_fees[tokenId][0], _fees[tokenId][1]);
        delete _fees[tokenId];
        _pay(_pos[tokenId].key.currency0, recipient, fee0);
        _pay(_pos[tokenId].key.currency1, recipient, fee1);
        emit FeesCollected(tokenId, recipient, fee0, fee1);
    }

    function _pay(Currency c, address to, uint256 amount) internal {
        if (amount == 0) return;
        address token = Currency.unwrap(c);
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth");
        } else {
            MockToken(token).mint(to, amount);
        }
    }

    receive() external payable {}
}
