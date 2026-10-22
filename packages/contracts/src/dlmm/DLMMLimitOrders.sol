// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {FixedPointMathLib as FPM} from "solady/utils/FixedPointMathLib.sol";
import {IDLMMLimitOrders, IDLMMPool, IDLMMFactory} from "../interfaces/IAethraPools.sol";

/// @title DLMMLimitOrders
/// @notice Limit orders on Aethra DLMM pools. An order is single-sided liquidity in one bin, owned by this
///         contract on behalf of the order owner. It fills as the active bin crosses the order's bin.
/// @dev A filled bin converts back if the price returns through it before the order is claimed: the order
///      is FILLED only while the active bin is beyond its bin, and its value follows the bin. Keepers can
///      lock in a fill for the owner with `claimFor`. Orders earn the bin's swap fees while they sit in it.
///      The first order (or deposit) in an empty bin locks the pool's MIN_SHARES dust.
///      Fee-on-transfer and rebasing tokens are not supported. UUPS proxy with ERC-7201 storage.
contract DLMMLimitOrders is IDLMMLimitOrders, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @custom:storage-location erc7201:aethra.storage.DLMMLimitOrders
    struct LimitOrdersStorage {
        address factory;
        uint256 lastId;
        mapping(uint256 => Order) orders;
        mapping(address => uint256[]) byOwner;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.DLMMLimitOrders")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LO_STORAGE = 0xcb9f5898c8e765f3827c49d3dad12d49d6d66413ea9af860ef8b9539c96b9c00;

    error Expired();
    error ZeroAmount();
    error UnknownPool();
    error UnknownOrder();
    error InvalidBin();
    error NotOrderOwner();
    error NotFilled();
    error OrderClosed();

    function _s() private pure returns (LimitOrdersStorage storage $) {
        assembly ("memory-safe") {
            $.slot := LO_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address factory_) external initializer {
        __Ownable_init(owner_);
        _s().factory = factory_;
    }

    function factory() external view returns (address) {
        return _s().factory;
    }

    // ------------------------------------------------------------------ actions

    function place(address pool, int24 binId, Side side, uint256 amountIn, uint256 deadline)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (block.timestamp > deadline) revert Expired();
        if (amountIn == 0) revert ZeroAmount();
        LimitOrdersStorage storage $ = _s();
        if (!IDLMMFactory($.factory).isPool(pool)) revert UnknownPool();
        int24 active = IDLMMPool(pool).activeId();
        bool sell0 = side == Side.SELL_TOKEN0;
        if (sell0 ? binId <= active : binId >= active) revert InvalidBin();

        IERC20 token = IERC20(sell0 ? IDLMMPool(pool).token0() : IDLMMPool(pool).token1());
        token.safeTransferFrom(msg.sender, address(this), amountIn);
        token.forceApprove(pool, amountIn);

        int24[] memory ids = new int24[](1);
        uint256[] memory a0 = new uint256[](1);
        uint256[] memory a1 = new uint256[](1);
        ids[0] = binId;
        (sell0 ? a0 : a1)[0] = amountIn;
        uint256 shares = IDLMMPool(pool).addLiquidity(ids, a0, a1, address(this), deadline)[0];

        orderId = ++$.lastId;
        $.orders[orderId] = Order({
            owner: msg.sender,
            pool: pool,
            binId: binId,
            side: side,
            amountIn: amountIn.toUint128(),
            shares: shares,
            createdAt: uint64(block.timestamp),
            closed: false
        });
        $.byOwner[msg.sender].push(orderId);
        emit OrderPlaced(orderId, msg.sender, pool, binId, side, amountIn);
    }

    function cancel(uint256 orderId, address recipient) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Order storage o = _open(orderId);
        if (msg.sender != o.owner) revert NotOrderOwner();
        (amount0, amount1) = _close(o, recipient);
        emit OrderCancelled(orderId, amount0, amount1);
    }

    function claim(uint256 orderId, address recipient) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Order storage o = _open(orderId);
        if (msg.sender != o.owner) revert NotOrderOwner();
        (amount0, amount1) = _claim(orderId, o, recipient);
    }

    /// @notice Keeper-friendly claim: anyone can send a FILLED order's proceeds to its owner.
    function claimFor(uint256 orderId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Order storage o = _open(orderId);
        (amount0, amount1) = _claim(orderId, o, o.owner);
    }

    function _claim(uint256 orderId, Order storage o, address recipient) private returns (uint256 amount0, uint256 amount1) {
        if (_status(o) != Status.FILLED) revert NotFilled();
        (amount0, amount1) = _close(o, recipient);
        emit OrderClaimed(orderId, amount0, amount1);
    }

    function _open(uint256 orderId) private view returns (Order storage o) {
        o = _s().orders[orderId];
        if (o.owner == address(0)) revert UnknownOrder();
        if (o.closed) revert OrderClosed();
    }

    function _close(Order storage o, address recipient) private returns (uint256 amount0, uint256 amount1) {
        o.closed = true;
        int24[] memory ids = new int24[](1);
        uint256[] memory shares = new uint256[](1);
        ids[0] = o.binId;
        shares[0] = o.shares;
        (amount0, amount1) = IDLMMPool(o.pool).removeLiquidity(ids, shares, 0, 0, recipient, block.timestamp);
    }

    // ------------------------------------------------------------------ views

    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _s().orders[orderId];
    }

    function status(uint256 orderId) external view returns (Status) {
        return _status(_s().orders[orderId]);
    }

    function _status(Order storage o) private view returns (Status) {
        if (o.owner == address(0)) return Status.NONE;
        if (o.closed) return Status.CLOSED;
        int24 active = IDLMMPool(o.pool).activeId();
        if (active == o.binId) return Status.PARTIAL;
        bool filled = o.side == Side.SELL_TOKEN0 ? active > o.binId : active < o.binId;
        return filled ? Status.FILLED : Status.OPEN;
    }

    function orderValue(uint256 orderId) external view returns (uint256 amount0, uint256 amount1) {
        Order storage o = _s().orders[orderId];
        if (o.owner == address(0) || o.closed) return (0, 0);
        (uint128 r0, uint128 r1, uint256 total) = IDLMMPool(o.pool).getBin(o.binId);
        amount0 = FPM.fullMulDiv(r0, o.shares, total);
        amount1 = FPM.fullMulDiv(r1, o.shares, total);
    }

    function ordersOf(address owner_) external view returns (uint256[] memory) {
        return _s().byOwner[owner_];
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
