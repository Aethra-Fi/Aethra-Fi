// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    string private _n;
    string private _s;
    uint8 private immutable _d;

    constructor(string memory n, string memory s, uint8 d) {
        (_n, _s, _d) = (n, s, d);
    }

    function name() public view override returns (string memory) {
        return _n;
    }

    function symbol() public view override returns (string memory) {
        return _s;
    }

    function decimals() public view override returns (uint8) {
        return _d;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
