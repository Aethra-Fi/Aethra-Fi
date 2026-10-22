// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LendingVault} from "../../src/credit/LendingVault.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {CreditBase} from "./LendingVault.t.sol";

/// @dev Acts as the vault's credit manager and drives random deposit / withdraw / borrow / repay / time sequences.
contract VaultHandler is Test {
    LendingVault public vault;
    MockToken public usd;
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];

    uint256 public ghostIn; // deposits + repayments into the vault
    uint256 public ghostOut; // withdrawals + loans + reserve withdrawals out of the vault
    uint256 public debtShares; // all outstanding debt shares (owned by this handler)
    uint256 public lastPrice;
    bool public priceDecreased;
    uint256 public time;

    constructor(LendingVault v, MockToken u) {
        (vault, usd) = (v, u);
        usd.approve(address(vault), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            vm.prank(actors[i]);
            usd.approve(address(vault), type(uint256).max);
        }
        lastPrice = vault.convertToAssets(1e18);
        time = block.timestamp;
    }

    function _check() internal {
        uint256 p = vault.convertToAssets(1e18);
        if (p < lastPrice) priceDecreased = true;
        lastPrice = p;
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % 3];
        amount = bound(amount, 1, 1_000_000e6);
        usd.mint(a, amount);
        vm.prank(a);
        vault.deposit(amount, a);
        ghostIn += amount;
        _check();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % 3];
        uint256 max = vault.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        vault.withdraw(amount, a, a);
        ghostOut += amount;
        _check();
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address a = actors[actorSeed % 3];
        uint256 max = vault.maxRedeem(a);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(a);
        ghostOut += vault.redeem(shares, a, a);
        _check();
    }

    function borrow(uint256 amount) external {
        uint256 cash = vault.availableCash();
        if (cash == 0) return;
        amount = bound(amount, 1, cash);
        debtShares += vault.lend(amount, address(this));
        ghostOut += amount;
        _check();
    }

    function repay(uint256 amount) external {
        if (debtShares == 0) return;
        uint256 owed = vault.debtSharesToAssets(debtShares);
        amount = bound(amount, 1, owed);
        usd.mint(address(this), amount);
        uint256 burned = vault.repayDebt(amount, address(this));
        debtShares = amount == owed ? 0 : debtShares - burned;
        ghostIn += amount;
        _check();
    }

    function warp(uint256 dt) external {
        time += bound(dt, 1, 60 days);
        vm.warp(time);
        _check();
        vault.accrueInterest();
        _check();
    }

    /// @notice Repay everything and let every LP exit as far as cash allows.
    function unwind() external {
        if (debtShares != 0) {
            uint256 owed = vault.debtSharesToAssets(debtShares);
            usd.mint(address(this), owed);
            vault.repayDebt(owed, address(this));
            ghostIn += owed;
            debtShares = 0;
        }
        for (uint256 i; i < 3; ++i) {
            uint256 s = vault.maxRedeem(actors[i]);
            if (s == 0) continue;
            vm.prank(actors[i]);
            ghostOut += vault.redeem(s, actors[i], actors[i]);
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 200
contract LendingVaultInvariantTest is CreditBase {
    LendingVault vault;
    MockToken usd;
    VaultHandler handler;

    function setUp() public {
        _deployHub();
        usd = new MockToken("tUSD", 6);
        vault = _deployVault(usd);
        handler = new VaultHandler(vault, usd);
        vm.prank(owner);
        vault.setCreditManager(address(handler));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = VaultHandler.deposit.selector;
        sel[1] = VaultHandler.withdraw.selector;
        sel[2] = VaultHandler.redeem.selector;
        sel[3] = VaultHandler.borrow.selector;
        sel[4] = VaultHandler.repay.selector;
        sel[5] = VaultHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), sel));
        targetContract(address(handler));
    }

    /// @dev Token conservation: the vault never pays out more than it took in.
    function invariant_conservation() public view {
        assertEq(usd.balanceOf(address(vault)), handler.ghostIn() - handler.ghostOut());
    }

    function invariant_sharePriceNeverDecreases() public view {
        assertFalse(handler.priceDecreased());
    }

    function invariant_claimsCoveredByAssets() public view {
        assertLe(vault.previewRedeem(vault.totalSupply()), vault.totalAssets());
        assertGe(vault.totalBorrows(), handler.debtShares() == 0 ? 0 : 1);
    }

    function invariant_reservesBacked() public view {
        assertLe(vault.protocolReserves(), usd.balanceOf(address(vault)) + vault.totalBorrows());
    }

    /// @dev After a full unwind, LPs exit and what remains covers the protocol reserves.
    function afterInvariant() public {
        handler.unwind();
        assertEq(vault.totalBorrows(), 0);
        assertGe(usd.balanceOf(address(vault)), vault.protocolReserves());
        assertEq(usd.balanceOf(address(vault)), handler.ghostIn() - handler.ghostOut());
        // remaining LP claims are dust (virtual-share rounding)
        assertLe(vault.previewRedeem(vault.totalSupply()), 10);
    }
}
