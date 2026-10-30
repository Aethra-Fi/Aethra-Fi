// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {IAethraHub} from "../../src/interfaces/IAethraHub.sol";
import {LendingVault} from "../../src/credit/LendingVault.sol";
import {MockToken} from "./mocks/MockToken.sol";

contract LendingVaultV2 is LendingVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Shared deployment helpers for credit tests.
abstract contract CreditBase is Test {
    address owner = address(0xA11CE);
    address treasury = address(0x7EA5);
    AethraHub hub;

    function _deployHub() internal {
        AethraHub impl = new AethraHub();
        hub = AethraHub(address(new ERC1967Proxy(address(impl), abi.encodeCall(AethraHub.initialize, (owner)))));
        vm.prank(owner);
        hub.setFeeConfig(address(0xB0B), treasury, 1000);
    }

    function _deployVault(MockToken usd) internal returns (LendingVault v) {
        LendingVault impl = new LendingVault();
        v = LendingVault(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        LendingVault.initialize, (IERC20(address(usd)), IAethraHub(address(hub)), owner, "Aethra USD Vault", "aUSD")
                    )
                )
            )
        );
    }
}

contract LendingVaultTest is CreditBase {
    LendingVault vault;
    MockToken usd;
    address lp = address(0x1111);
    address lp2 = address(0x2222);
    address borrower = address(0xB022);
    uint256 constant UNIT = 1e6;

    function setUp() public {
        _deployHub();
        usd = new MockToken("tUSD", 6);
        vault = _deployVault(usd);
        vm.prank(owner);
        vault.setCreditManager(address(this)); // this test acts as the credit manager
        usd.approve(address(vault), type(uint256).max);
        _fund(lp, 10_000_000 * UNIT);
        _fund(lp2, 10_000_000 * UNIT);
    }

    function _fund(address who, uint256 amt) internal {
        usd.mint(who, amt);
        vm.prank(who);
        usd.approve(address(vault), type(uint256).max);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(amt, who);
    }

    function test_initialState() public view {
        assertEq(vault.asset(), address(usd));
        assertEq(vault.decimals(), 12); // 6 + offset 6
        assertEq(vault.owner(), owner);
        assertEq(vault.borrowIndexRay(), 1e27);
        (uint256 base, uint256 s1, uint256 s2, uint16 kink, uint16 rf) = vault.rateModel();
        assertEq(base, 0);
        assertEq(s1, 0.04e18);
        assertEq(s2, 3e18);
        assertEq(kink, 8000);
        assertEq(rf, 1000);
    }

    function test_cannotReinitialize() public {
        vm.expectRevert();
        vault.initialize(IERC20(address(usd)), IAethraHub(address(hub)), owner, "x", "x");
    }

    function test_depositWithdraw() public {
        uint256 shares = _deposit(lp, 1000 * UNIT);
        assertEq(vault.balanceOf(lp), shares);
        assertEq(vault.totalAssets(), 1000 * UNIT);
        vm.prank(lp);
        vault.withdraw(400 * UNIT, lp, lp);
        assertEq(vault.totalAssets(), 600 * UNIT);
        assertEq(usd.balanceOf(lp), 10_000_000 * UNIT - 600 * UNIT);
    }

    function test_onlyCreditManagerLends() public {
        _deposit(lp, 1000 * UNIT);
        vm.prank(borrower);
        vm.expectRevert(LendingVault.NotCreditManager.selector);
        vault.lend(1, borrower);
        vm.prank(borrower);
        vm.expectRevert(LendingVault.NotCreditManager.selector);
        vault.repayDebt(1, borrower);
    }

    function test_interestAccrualAtKink() public {
        _deposit(lp, 1_000_000 * UNIT);
        uint256 shares = vault.lend(800_000 * UNIT, borrower);
        assertEq(usd.balanceOf(borrower), 800_000 * UNIT);
        assertEq(vault.utilizationBps(), 8000);
        assertApproxEqRel(vault.borrowRatePerSecondWad() * 365 days, 0.04e18, 1e12);

        vm.warp(block.timestamp + 365 days);
        // simple interest across one accrual period: 4% of 800k
        assertApproxEqRel(vault.totalBorrows(), 832_000 * UNIT, 1e12);
        assertApproxEqRel(vault.protocolReserves(), 3_200 * UNIT, 1e12);
        assertApproxEqRel(vault.totalAssets(), 1_028_800 * UNIT, 1e12);
        assertApproxEqRel(vault.debtSharesToAssets(shares), 832_000 * UNIT, 1e12);

        // views match state after an explicit accrual
        uint256 ta = vault.totalAssets();
        vault.accrueInterest();
        assertEq(vault.totalAssets(), ta);
        assertApproxEqRel(vault.borrowIndexRay(), 1.04e27, 1e12);
    }

    function test_kinkedRates() public {
        _deposit(lp, 1_000_000 * UNIT);
        vault.lend(400_000 * UNIT, borrower); // 40%: half of slope1
        assertApproxEqRel(vault.borrowRatePerSecondWad() * 365 days, 0.02e18, 1e12);
        vault.lend(500_000 * UNIT, borrower); // 90%: slope1 + half of slope2
        assertEq(vault.utilizationBps(), 9000);
        uint256 br = vault.borrowRatePerSecondWad();
        assertApproxEqRel(br * 365 days, 1.54e18, 1e12);
        assertApproxEqRel(vault.supplyRatePerSecondWad(), br * 9 / 10 * 9 / 10, 1e12);
        vault.lend(100_000 * UNIT, borrower); // 100%
        assertApproxEqRel(vault.borrowRatePerSecondWad() * 365 days, 3.04e18, 1e12);
    }

    function test_compoundingAcrossAccruals() public {
        _deposit(lp, 1_000_000 * UNIT);
        vault.lend(500_000 * UNIT, borrower);
        uint256 last = vault.totalBorrows();
        uint256 t = block.timestamp;
        for (uint256 i; i < 12; ++i) {
            t += 30 days; // via-ir caches block.timestamp within a function, so track time locally
            vm.warp(t);
            vault.accrueInterest();
            uint256 b = vault.totalBorrows();
            assertGt(b, last);
            last = b;
        }
    }

    function test_repayReducesDebt() public {
        _deposit(lp, 1_000_000 * UNIT);
        uint256 shares = vault.lend(100_000 * UNIT, borrower);
        vm.warp(block.timestamp + 100 days);
        uint256 owed = vault.debtSharesToAssets(shares);
        usd.mint(address(this), owed);
        uint256 burned = vault.repayDebt(owed, address(this));
        assertEq(burned, shares);
        assertEq(vault.totalBorrows(), 0);
        assertEq(vault.totalDebtShares(), 0);
        assertGt(vault.totalAssets(), 1_000_000 * UNIT);
    }

    function test_withdrawLimitedByCash() public {
        _deposit(lp, 1_000 * UNIT);
        vault.lend(900 * UNIT, borrower);
        assertEq(vault.maxWithdraw(lp), 100 * UNIT);
        assertEq(vault.maxRedeem(lp), vault.convertToShares(100 * UNIT));
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, lp, 101 * UNIT, 100 * UNIT)
        );
        vault.withdraw(101 * UNIT, lp, lp);
        vm.prank(lp);
        vault.withdraw(100 * UNIT, lp, lp);
        assertEq(vault.availableCash(), 0);
    }

    function test_reservesNotWithdrawableByLps() public {
        _deposit(lp, 1_000 * UNIT);
        uint256 shares = vault.lend(800 * UNIT, borrower);
        vm.warp(block.timestamp + 365 days);
        uint256 owed = vault.debtSharesToAssets(shares);
        usd.mint(address(this), owed);
        vault.repayDebt(owed, address(this));
        uint256 reserves = vault.protocolReserves();
        assertGt(reserves, 0);
        assertLe(vault.maxWithdraw(lp), usd.balanceOf(address(vault)) - reserves);
        vm.startPrank(lp);
        vault.redeem(vault.maxRedeem(lp), lp, lp);
        vm.stopPrank();
        assertGe(usd.balanceOf(address(vault)), reserves);

        vm.prank(borrower);
        vm.expectRevert();
        vault.withdrawReserves(reserves);
        vm.prank(owner);
        vault.withdrawReserves(type(uint256).max);
        assertEq(usd.balanceOf(treasury), reserves);
        assertEq(vault.protocolReserves(), 0);
    }

    function test_supplyCap() public {
        vm.prank(owner);
        vault.setCaps(1_000 * UNIT, type(uint256).max);
        assertEq(vault.maxDeposit(lp), 1_000 * UNIT);
        _deposit(lp, 600 * UNIT);
        assertEq(vault.maxDeposit(lp), 400 * UNIT);
        vm.prank(lp2);
        vm.expectRevert();
        vault.deposit(401 * UNIT, lp2);
        _deposit(lp2, 400 * UNIT);
        assertEq(vault.maxDeposit(lp), 0);
        assertEq(vault.maxMint(lp), 0);
    }

    function test_borrowCapAndCash() public {
        _deposit(lp, 1_000 * UNIT);
        vm.prank(owner);
        vault.setCaps(type(uint256).max, 500 * UNIT);
        vault.lend(500 * UNIT, borrower);
        vm.expectRevert(LendingVault.BorrowCapExceeded.selector);
        vault.lend(1, borrower);
        vm.prank(owner);
        vault.setCaps(type(uint256).max, type(uint256).max);
        vm.expectRevert(LendingVault.InsufficientCash.selector);
        vault.lend(501 * UNIT, borrower);
    }

    function test_adminParamValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(LendingVault.InvalidParams.selector);
        vault.setRateModel(0, 0.04e18, 3e18, 0);
        vm.expectRevert(LendingVault.InvalidParams.selector);
        vault.setRateModel(0, 0.04e18, 3e18, 10_000);
        vm.expectRevert(LendingVault.InvalidParams.selector);
        vault.setRateModel(0, 0, 51e18, 5000);
        vm.expectRevert(LendingVault.InvalidParams.selector);
        vault.setReserveFactor(5001);
        vault.setRateModel(0.01e18, 0.1e18, 1e18, 9000);
        vault.setReserveFactor(2000);
        vm.stopPrank();
        vm.expectRevert();
        vault.setCreditManager(address(1));
    }

    function test_inflationAttackMitigated() public {
        address attacker = address(0xBAD);
        _fund(attacker, 1_000_001 * UNIT);
        vm.startPrank(attacker);
        vault.deposit(1, attacker);
        usd.transfer(address(vault), 1_000_000 * UNIT); // donation
        vm.stopPrank();
        uint256 shares = _deposit(lp, 1_000 * UNIT);
        assertGt(shares, 0);
        // victim keeps (almost) all of its deposit
        assertApproxEqRel(vault.previewRedeem(shares), 1_000 * UNIT, 0.01e18);
        // attacker cannot profit
        assertLt(vault.previewRedeem(vault.balanceOf(attacker)), 1_000_001 * UNIT);
    }

    function test_vault18Decimals() public {
        MockToken usd18 = new MockToken("tUSD18", 18);
        LendingVault v = _deployVault(usd18);
        vm.prank(owner);
        v.setCreditManager(address(this));
        assertEq(v.decimals(), 24);
        usd18.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        usd18.approve(address(v), type(uint256).max);
        v.deposit(1_000_000e18, lp);
        vm.stopPrank();
        v.lend(800_000e18, borrower);
        vm.warp(block.timestamp + 365 days);
        assertApproxEqRel(v.totalAssets(), 1_028_800e18, 1e12);
    }

    function test_upgradeKeepsState() public {
        _deposit(lp, 1_000 * UNIT);
        vault.lend(300 * UNIT, borrower);
        vm.warp(block.timestamp + 10 days);
        uint256 ta = vault.totalAssets();
        uint256 tb = vault.totalBorrows();
        LendingVaultV2 v2 = new LendingVaultV2();
        vm.expectRevert();
        vault.upgradeToAndCall(address(v2), "");
        vm.prank(owner);
        vault.upgradeToAndCall(address(v2), "");
        assertEq(LendingVaultV2(address(vault)).version(), 2);
        assertEq(vault.totalAssets(), ta);
        assertEq(vault.totalBorrows(), tb);
        assertEq(vault.creditManager(), address(this));
    }

    function test_implementationLocked() public {
        LendingVault impl = new LendingVault();
        vm.expectRevert();
        impl.initialize(IERC20(address(usd)), IAethraHub(address(hub)), owner, "x", "x");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_accrualNeverDecreasesSharePrice(uint96 dep, uint96 borrowAmt, uint32 dt) public {
        uint256 d = bound(dep, UNIT, 5_000_000 * UNIT);
        uint256 b = bound(borrowAmt, 1, d);
        _deposit(lp, d);
        uint256 p0 = vault.convertToAssets(1e18);
        vault.lend(b, borrower);
        assertGe(vault.convertToAssets(1e18), p0);
        vm.warp(block.timestamp + bound(dt, 1, 10 * 365 days));
        uint256 p1 = vault.convertToAssets(1e18);
        assertGe(p1, p0);
        vault.accrueInterest();
        assertGe(vault.convertToAssets(1e18), p1);
        assertLe(vault.protocolReserves(), vault.totalBorrows() - b + 1);
    }
}
