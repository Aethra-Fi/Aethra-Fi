// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {IAethraPositions} from "../../../src/interfaces/IAethraPeriphery.sol";

/// @notice WETH9-like mock. Name/symbol are constants so the code can be vm.etch'ed to any address.
contract MockWETH is ERC20 {
    function name() public pure override returns (string memory) {
        return "Wrapped Ether";
    }

    function symbol() public pure override returns (string memory) {
        return "WETH";
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

/// @notice Records initialize() and exposes slot0 through extsload like the real PoolManager.
contract MockPoolManager {
    struct InitCall {
        PoolKey key;
        uint160 sqrtPriceX96;
    }

    mapping(bytes32 => uint160) public sqrtPriceOf;
    mapping(bytes32 => bytes32) internal _slots;
    InitCall internal _last;
    uint256 public initCount;

    error AlreadyInitialized();

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        bytes32 id = keccak256(abi.encode(key));
        if (sqrtPriceOf[id] != 0) revert AlreadyInitialized();
        require(Currency.unwrap(key.currency0) < Currency.unwrap(key.currency1), "unsorted");
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        sqrtPriceOf[id] = sqrtPriceX96;
        _slots[keccak256(abi.encodePacked(id, bytes32(uint256(6))))] =
            bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160));
        _last = InitCall(key, sqrtPriceX96);
        initCount++;
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function lastInit() external view returns (PoolKey memory key, uint160 sqrtPriceX96) {
        return (_last.key, _last.sqrtPriceX96);
    }
}

/// @notice Pulls tokens for a mint at the mock pool price, records mints/locks, pays seeded fees on collect.
contract MockPositions {
    MockPoolManager public immutable manager;
    uint256 public nextTokenId = 1;

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => IAethraPositions.MintParams) internal _mints;
    mapping(uint256 => IAethraPositions.Lock) internal _locks;
    mapping(uint256 => uint256[2]) public seededFees;
    uint256 public lastAmount0;
    uint256 public lastAmount1;

    constructor(MockPoolManager m) {
        manager = m;
    }

    function mint(IAethraPositions.MintParams calldata p)
        external
        returns (uint256 tokenId, uint256 amount0, uint256 amount1)
    {
        require(block.timestamp <= p.deadline, "expired");
        uint160 sqrtP = manager.sqrtPriceOf(keccak256(abi.encode(p.key)));
        require(sqrtP != 0, "not initialized");
        uint160 sa = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(p.tickUpper);
        uint160 sp = sqrtP < sa ? sa : (sqrtP > sb ? sb : sqrtP);
        amount0 = SqrtPriceMath.getAmount0Delta(sp, sb, p.liquidity, true);
        amount1 = SqrtPriceMath.getAmount1Delta(sa, sp, p.liquidity, true);
        require(amount0 <= p.amount0Max && amount1 <= p.amount1Max, "slippage");
        IERC20(Currency.unwrap(p.key.currency0)).transferFrom(msg.sender, address(this), amount0);
        IERC20(Currency.unwrap(p.key.currency1)).transferFrom(msg.sender, address(this), amount1);
        tokenId = nextTokenId++;
        ownerOf[tokenId] = p.recipient;
        _mints[tokenId] = p;
        (lastAmount0, lastAmount1) = (amount0, amount1);
        if (p.recipient.code.length != 0) {
            require(
                IERC721Receiver(p.recipient).onERC721Received(msg.sender, address(0), tokenId, "")
                    == IERC721Receiver.onERC721Received.selector,
                "receiver"
            );
        }
    }

    function lock(uint256 tokenId, uint64 cliff, uint64 end) external {
        require(msg.sender == ownerOf[tokenId], "not owner");
        _locks[tokenId] = IAethraPositions.Lock(cliff, end, _mints[tokenId].liquidity, 0);
    }

    function seedFees(uint256 tokenId, uint256 fee0, uint256 fee1) external {
        seededFees[tokenId] = [fee0, fee1];
    }

    function collect(uint256 tokenId, address recipient) external returns (uint256 fee0, uint256 fee1) {
        require(msg.sender == ownerOf[tokenId], "not owner");
        (fee0, fee1) = (seededFees[tokenId][0], seededFees[tokenId][1]);
        delete seededFees[tokenId];
        IAethraPositions.MintParams storage p = _mints[tokenId];
        if (fee0 != 0) IERC20(Currency.unwrap(p.key.currency0)).transfer(recipient, fee0);
        if (fee1 != 0) IERC20(Currency.unwrap(p.key.currency1)).transfer(recipient, fee1);
    }

    function getMint(uint256 tokenId) external view returns (IAethraPositions.MintParams memory) {
        return _mints[tokenId];
    }

    function getLock(uint256 tokenId) external view returns (IAethraPositions.Lock memory) {
        return _locks[tokenId];
    }
}
