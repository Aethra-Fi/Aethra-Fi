// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IAethraRouter} from "../interfaces/IAethraPeriphery.sol";
import {IAethraHub, Venue} from "../interfaces/IAethraHub.sol";
import {IAethraPool, IAethraLaunchpad} from "../interfaces/IAethraPools.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title AethraRouter
/// @notice Exact-input router across Uniswap v4 pools (with or without the Aethra hook), Aethra DLMM and DAMM
///         pools, and launchpad bonding curves. Routes are chosen off-chain; `quote` simulates them on-chain.
contract AethraRouter is IAethraRouter, IUnlockCallback, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:aethra.storage.Router
    struct RouterStorage {
        IAethraHub hub;
    }

    // scripts/erc7201.sh aethra.storage.Router
    bytes32 private constant ROUTER_STORAGE = 0xb7036d6cbfcef5661710e2bb84ed50195c3c2257b110b3d6f08e0270658da900;

    IPoolManager public immutable poolManager;
    address public immutable weth;

    error PoolNotEnabled();
    error InsufficientOutput();

    constructor(IPoolManager poolManager_, address weth_) {
        poolManager = poolManager_;
        weth = weth_;
        _disableInitializers();
    }

    function initialize(address owner_, IAethraHub hub_) external initializer {
        __Ownable_init(owner_);
        _s().hub = hub_;
    }

    function _s() private pure returns (RouterStorage storage $) {
        assembly {
            $.slot := ROUTER_STORAGE
        }
    }

    receive() external payable {
        if (msg.sender != weth) revert BadRoute();
    }

    function hub() external view returns (IAethraHub) {
        return _s().hub;
    }

    // ------------------------------------------------------------------ swap

    function swap(Hop[] calldata hops, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline, bool unwrapETH)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        uint256 n = hops.length;
        if (n == 0 || n > 4 || amountIn == 0) revert BadRoute();
        for (uint256 i = 1; i < n; i++) {
            if (hops[i].tokenIn != hops[i - 1].tokenOut) revert BadRoute();
        }
        address tokenOut = hops[n - 1].tokenOut;
        if (unwrapETH && tokenOut != weth) revert BadRoute();

        if (msg.value != 0) {
            if (hops[0].tokenIn != weth || msg.value != amountIn) revert BadRoute();
            IWETH9(weth).deposit{value: msg.value}();
        } else {
            IERC20(hops[0].tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        amountOut = amountIn;
        for (uint256 i; i < n; i++) {
            address to = (i == n - 1 && !unwrapETH) ? recipient : address(this);
            amountOut = _execute(hops[i], amountOut, to, deadline);
        }
        if (amountOut < minAmountOut) revert Slippage();

        if (unwrapETH) {
            IWETH9(weth).withdraw(amountOut);
            (bool ok,) = recipient.call{value: amountOut}("");
            if (!ok) revert BadRoute();
        }
        emit RouteExecuted(msg.sender, recipient, hops[0].tokenIn, tokenOut, amountIn, amountOut, uint8(n));
    }

    function _execute(Hop calldata h, uint256 amountIn, address to, uint256 deadline) internal returns (uint256 out) {
        if (h.venue == Venue.V4) {
            PoolKey memory key = abi.decode(h.data, (PoolKey));
            bool zeroForOne = _direction(key, h.tokenIn, h.tokenOut);
            bytes memory r = poolManager.unlock(abi.encode(false, key, zeroForOne, amountIn, to));
            return abi.decode(r, (uint256));
        }
        if (h.venue == Venue.DLMM || h.venue == Venue.DAMM) {
            if (!_s().hub.isPoolEnabled(bytes32(uint256(uint160(h.pool))))) revert PoolNotEnabled();
            IERC20(h.tokenIn).forceApprove(h.pool, amountIn);
            return IAethraPool(h.pool).swapExactInput(h.tokenIn, amountIn, 0, to, deadline);
        }
        if (h.venue == Venue.LAUNCH) {
            address token = abi.decode(h.data, (address));
            if (!_s().hub.isPoolEnabled(bytes32(uint256(uint160(token))))) revert PoolNotEnabled();
            IERC20(h.tokenIn).forceApprove(h.pool, amountIn);
            return IAethraLaunchpad(h.pool).swapExactInput(token, h.tokenIn, amountIn, 0, to, deadline);
        }
        revert BadVenue();
    }

    // ------------------------------------------------------------------ quote

    /// @inheritdoc IAethraRouter
    function quote(Hop[] calldata hops, uint256 amountIn) external returns (uint256 amountOut, uint256[] memory hopAmounts) {
        uint256 n = hops.length;
        if (n == 0) revert BadRoute();
        hopAmounts = new uint256[](n);
        amountOut = amountIn;
        for (uint256 i; i < n; i++) {
            Hop calldata h = hops[i];
            if (i > 0 && h.tokenIn != hops[i - 1].tokenOut) revert BadRoute();
            if (h.venue == Venue.V4) {
                PoolKey memory key = abi.decode(h.data, (PoolKey));
                amountOut = _quoteV4(key, _direction(key, h.tokenIn, h.tokenOut), amountOut);
            } else if (h.venue == Venue.DLMM || h.venue == Venue.DAMM) {
                (amountOut,) = IAethraPool(h.pool).quoteExactInput(h.tokenIn, amountOut);
            } else if (h.venue == Venue.LAUNCH) {
                amountOut = IAethraLaunchpad(h.pool).quoteExactInput(abi.decode(h.data, (address)), h.tokenIn, amountOut);
            } else {
                revert BadVenue();
            }
            hopAmounts[i] = amountOut;
        }
    }

    function _quoteV4(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        try poolManager.unlock(abi.encode(true, key, zeroForOne, amountIn, address(0))) {
            return 0; // unreachable: quote mode always reverts
        } catch (bytes memory reason) {
            if (reason.length >= 36 && bytes4(reason) == QuoteResult.selector) {
                uint256 out;
                assembly {
                    out := mload(add(reason, 36))
                }
                return out;
            }
            return 0; // pool missing, paused, breaker, or insufficient liquidity
        }
    }

    // ------------------------------------------------------------------ v4 callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bool quoting, PoolKey memory key, bool zeroForOne, uint256 amountIn, address to) =
            abi.decode(data, (bool, PoolKey, bool, uint256, address));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 dIn, int128 dOut) = zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 paid = uint256(uint128(-dIn));
        uint256 out = uint256(uint128(dOut));
        if (quoting) {
            // partial fills (price limit hit) are reported as zero output
            revert QuoteResult(paid == amountIn ? out : 0, new uint256[](0));
        }
        if (paid != amountIn) revert InsufficientOutput();

        (Currency cIn, Currency cOut) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        poolManager.sync(cIn);
        IERC20(Currency.unwrap(cIn)).safeTransfer(address(poolManager), paid);
        poolManager.settle();
        poolManager.take(cOut, to, out);
        return abi.encode(out);
    }

    function _direction(PoolKey memory key, address tokenIn, address tokenOut) internal pure returns (bool zeroForOne) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (tokenIn == c0 && tokenOut == c1) return true;
        if (tokenIn == c1 && tokenOut == c0) return false;
        revert BadRoute();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
