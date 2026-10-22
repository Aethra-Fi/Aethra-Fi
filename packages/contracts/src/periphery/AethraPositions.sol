// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {IAethraPositions} from "../interfaces/IAethraPeriphery.sol";

/// @title AethraPositions
/// @notice ERC-721 liquidity positions on Uniswap v4 with built-in locks and linear vesting.
///         Each NFT is one v4 position owned by this contract, keyed by salt = bytes32(tokenId).
///         Tokens are pulled from msg.sender with transferFrom (approve this contract first).
/// @dev Native-currency pools are not supported (Aethra uses WETH everywhere).
contract AethraPositions is
    IAethraPositions,
    IUnlockCallback,
    ERC721Upgradeable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransient
{
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:aethra.storage.Positions
    struct PositionsStorage {
        uint256 nextTokenId;
        mapping(uint256 => Position) positions;
        mapping(uint256 => Lock) locks;
    }

    // scripts/erc7201.sh aethra.storage.Positions
    bytes32 private constant POSITIONS_STORAGE = 0x1161498a9f62cefd428a307d6b57a4df6e638608f39961349348783647b59000;

    IPoolManager public immutable poolManager;

    error NativeNotSupported();
    error NotEmpty();
    error UnknownPosition();

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __ERC721_init("Aethra Liquidity Position", "AETHRA-LP");
        __Ownable_init(owner_);
        _s().nextTokenId = 1;
    }

    function _s() private pure returns (PositionsStorage storage $) {
        assembly {
            $.slot := POSITIONS_STORAGE
        }
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    modifier onlyAuthorized(uint256 tokenId) {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) revert NotOwnerOrApproved();
        _;
    }

    // ------------------------------------------------------------------ actions

    enum Action {
        MODIFY,
        COLLECT
    }

    struct CallbackData {
        Action action;
        uint256 tokenId;
        int256 liquidityDelta;
        address payer;
        address recipient;
    }

    function mint(MintParams calldata p)
        external
        nonReentrant
        checkDeadline(p.deadline)
        returns (uint256 tokenId, uint256 amount0, uint256 amount1)
    {
        if (p.key.currency0.isAddressZero()) revert NativeNotSupported();
        PositionsStorage storage $ = _s();
        tokenId = $.nextTokenId++;
        $.positions[tokenId] = Position(p.key, p.tickLower, p.tickUpper, 0);
        _mint(p.recipient, tokenId);
        emit Minted(tokenId, p.recipient, PoolId.unwrap(p.key.toId()), p.tickLower, p.tickUpper);

        (int256 d0, int256 d1) = _modify(tokenId, int256(uint256(p.liquidity)), msg.sender, p.recipient);
        (amount0, amount1) = (_neg(d0), _neg(d1));
        if (amount0 > p.amount0Max || amount1 > p.amount1Max) revert Slippage();
    }

    function increaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Max, uint256 amount1Max, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        address owner_ = _requireOwned(tokenId);
        Lock storage l = _s().locks[tokenId];
        // liquidity added to an active lock follows that lock
        if (_lockActive(l)) l.lockedLiquidity += liquidity;
        (int256 d0, int256 d1) = _modify(tokenId, int256(uint256(liquidity)), msg.sender, owner_);
        (amount0, amount1) = (_neg(d0), _neg(d1));
        if (amount0 > amount0Max || amount1 > amount1Max) revert Slippage();
    }

    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    ) external nonReentrant checkDeadline(deadline) onlyAuthorized(tokenId) returns (uint256 amount0, uint256 amount1) {
        if (liquidity > withdrawable(tokenId)) revert LockedLiquidity();
        Lock storage l = _s().locks[tokenId];
        if (_lockActive(l)) l.withdrawn += liquidity; // informational: liquidity removed while the lock runs
        (int256 d0, int256 d1) = _modify(tokenId, -int256(uint256(liquidity)), address(0), recipient);
        (amount0, amount1) = (_pos(d0), _pos(d1));
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();
    }

    function collect(uint256 tokenId, address recipient)
        external
        nonReentrant
        onlyAuthorized(tokenId)
        returns (uint256 fee0, uint256 fee1)
    {
        if (_s().positions[tokenId].liquidity == 0) return (0, 0);
        bytes memory r = poolManager.unlock(abi.encode(CallbackData(Action.COLLECT, tokenId, 0, address(0), recipient)));
        (int256 d0, int256 d1) = abi.decode(r, (int256, int256));
        (fee0, fee1) = (_pos(d0), _pos(d1));
        emit FeesCollected(tokenId, recipient, fee0, fee1);
    }

    function burn(uint256 tokenId) external onlyAuthorized(tokenId) {
        if (_s().positions[tokenId].liquidity != 0) revert NotEmpty();
        delete _s().positions[tokenId];
        delete _s().locks[tokenId];
        _burn(tokenId);
    }

    function lock(uint256 tokenId, uint64 cliff, uint64 end) external onlyAuthorized(tokenId) {
        if (end < cliff || end <= block.timestamp) revert InvalidLock();
        Lock storage l = _s().locks[tokenId];
        // an active lock can only become stricter; the new schedule always covers all current liquidity
        if (_lockActive(l) && (cliff < l.cliff || end < l.end)) revert InvalidLock();
        uint128 liq = _s().positions[tokenId].liquidity;
        (l.cliff, l.end, l.lockedLiquidity, l.withdrawn) = (cliff, end, liq, 0);
        emit Locked(tokenId, cliff, end, liq);
    }

    // ------------------------------------------------------------------ views

    function getPosition(uint256 tokenId) external view returns (Position memory) {
        return _s().positions[tokenId];
    }

    function getLock(uint256 tokenId) external view returns (Lock memory) {
        return _s().locks[tokenId];
    }

    function withdrawable(uint256 tokenId) public view returns (uint128) {
        uint128 liq = _s().positions[tokenId].liquidity;
        uint128 locked = _lockedNow(_s().locks[tokenId]);
        return liq > locked ? liq - locked : 0;
    }

    function positionAmounts(uint256 tokenId) external view returns (uint256 amount0, uint256 amount1) {
        Position memory p = _s().positions[tokenId];
        if (p.liquidity == 0) return (0, 0);
        (uint160 sqrtP,,,) = poolManager.getSlot0(p.key.toId());
        uint160 sa = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 sb = TickMath.getSqrtPriceAtTick(p.tickUpper);
        if (sqrtP <= sa) {
            amount0 = SqrtPriceMath.getAmount0Delta(sa, sb, p.liquidity, false);
        } else if (sqrtP < sb) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sb, p.liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sa, sqrtP, p.liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sa, sb, p.liquidity, false);
        }
    }

    function nextTokenId() external view returns (uint256) {
        return _s().nextTokenId;
    }

    function ownerOf(uint256 tokenId) public view override(ERC721Upgradeable, IAethraPositions) returns (address) {
        return super.ownerOf(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        Position memory p = _s().positions[tokenId];
        return string.concat(
            "data:application/json;utf8,{\"name\":\"Aethra LP #",
            Strings.toString(tokenId),
            "\",\"description\":\"Aethra Fi liquidity position\",\"attributes\":[{\"trait_type\":\"pool\",\"value\":\"",
            Strings.toHexString(uint256(PoolId.unwrap(p.key.toId())), 32),
            "\"},{\"trait_type\":\"tickLower\",\"value\":\"",
            Strings.toStringSigned(p.tickLower),
            "\"},{\"trait_type\":\"tickUpper\",\"value\":\"",
            Strings.toStringSigned(p.tickUpper),
            "\"}]}"
        );
    }

    // ------------------------------------------------------------------ v4 plumbing

    function _modify(uint256 tokenId, int256 liquidityDelta, address payer, address recipient)
        internal
        returns (int256 d0, int256 d1)
    {
        bytes memory r = poolManager.unlock(
            abi.encode(CallbackData(Action.MODIFY, tokenId, liquidityDelta, payer, recipient))
        );
        (d0, d1) = abi.decode(r, (int256, int256));
        Position storage p = _s().positions[tokenId];
        p.liquidity = uint128(uint256(int256(uint256(p.liquidity)) + liquidityDelta));
        emit LiquidityChanged(tokenId, liquidityDelta, d0, d1);
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory cb = abi.decode(raw, (CallbackData));
        Position memory p = _s().positions[cb.tokenId];

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            p.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: cb.liquidityDelta,
                salt: bytes32(cb.tokenId)
            }),
            ""
        );
        int256 d0 = delta.amount0();
        int256 d1 = delta.amount1();
        _settle(p.key.currency0, d0, cb.payer, cb.recipient);
        _settle(p.key.currency1, d1, cb.payer, cb.recipient);
        return abi.encode(d0, d1);
    }

    /// @dev Negative delta = we owe the pool (pull from payer); positive = pool owes us (send to recipient).
    function _settle(Currency currency, int256 delta, address payer, address recipient) internal {
        if (delta < 0) {
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), uint256(-delta));
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, recipient, uint256(delta));
        }
    }

    function _lockActive(Lock memory l) internal view returns (bool) {
        return l.end != 0 && (l.end == type(uint64).max || block.timestamp < l.end);
    }

    /// @dev Liquidity that must stay in the position right now: all of it before the cliff (or forever for a
    ///      permanent lock), then linearly less until `end`. Liquidity added mid-schedule vests on the same curve.
    function _lockedNow(Lock memory l) internal view returns (uint128) {
        if (!_lockActive(l)) return 0;
        if (l.end == type(uint64).max || block.timestamp < l.cliff) return l.lockedLiquidity;
        uint256 vested = uint256(l.lockedLiquidity) * (block.timestamp - l.cliff) / (l.end - l.cliff);
        return uint128(uint256(l.lockedLiquidity) - vested);
    }

    function _neg(int256 d) private pure returns (uint256) {
        return d < 0 ? uint256(-d) : 0;
    }

    function _pos(int256 d) private pure returns (uint256) {
        return d > 0 ? uint256(d) : 0;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
