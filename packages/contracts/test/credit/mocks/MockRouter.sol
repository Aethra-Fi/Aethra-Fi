// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAethraRouter} from "../../../src/interfaces/IAethraPeriphery.sol";
import {MockToken} from "./MockToken.sol";

/// @notice Router stand-in: each hop converts at a settable WAD rate (out = in * rate / 1e18) and the output of the
///         last hop is minted to the recipient. ETH sent with tokenIn == weth is accepted as the input.
contract MockRouter is IAethraRouter {
    address public immutable weth;
    mapping(address => mapping(address => uint256)) public rate;

    constructor(address weth_) {
        weth = weth_;
    }

    function setRate(address tokenIn, address tokenOut, uint256 rateWad) external {
        rate[tokenIn][tokenOut] = rateWad;
    }

    function swap(Hop[] calldata hops, uint256 amountIn, uint256 minAmountOut, address recipient, uint256 deadline, bool)
        external
        payable
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (hops.length == 0) revert BadRoute();
        if (msg.value != 0) {
            if (hops[0].tokenIn != weth || msg.value != amountIn) revert BadRoute();
        } else {
            IERC20(hops[0].tokenIn).transferFrom(msg.sender, address(this), amountIn);
        }
        (amountOut,) = _quote(hops, amountIn);
        if (amountOut < minAmountOut) revert Slippage();
        MockToken(hops[hops.length - 1].tokenOut).mint(recipient, amountOut);
        emit RouteExecuted(msg.sender, recipient, hops[0].tokenIn, hops[hops.length - 1].tokenOut, amountIn, amountOut, uint8(hops.length));
    }

    function quote(Hop[] calldata hops, uint256 amountIn) external view returns (uint256, uint256[] memory) {
        return _quote(hops, amountIn);
    }

    function _quote(Hop[] calldata hops, uint256 amountIn) internal view returns (uint256 out, uint256[] memory amts) {
        amts = new uint256[](hops.length);
        out = amountIn;
        for (uint256 i; i < hops.length; ++i) {
            if (i > 0 && hops[i].tokenIn != hops[i - 1].tokenOut) revert BadRoute();
            out = out * rate[hops[i].tokenIn][hops[i].tokenOut] / 1e18;
            amts[i] = out;
        }
    }
}
