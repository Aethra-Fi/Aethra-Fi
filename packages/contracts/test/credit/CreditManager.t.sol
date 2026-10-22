// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IAethraHub, Venue, AssetClass} from "../../src/interfaces/IAethraHub.sol";
import {
    ICreditManager, ILendingVault, IAethraPositions, IAethraRouter
} from "../../src/interfaces/IAethraPeriphery.sol";
import {LendingVault} from "../../src/credit/LendingVault.sol";
import {CreditManager} from "../../src/credit/CreditManager.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockPositions} from "./mocks/MockPositions.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {CreditBase} from "./LendingVault.t.sol";

contract CreditManagerV2 is CreditManager {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract CreditManagerTest is CreditBase {
    LendingVault vault;
    CreditManager cm;
    MockToken usd;
    MockToken weth;
    MockToken tsla;
    MockPriceFeed wethFeed;
    MockPriceFeed tslaFeed;
    MockPositions positions;
    MockRouter router;
    PoolKey key;

    address lp = address(0x1111);
    address alice = address(0xA71CE);
    address liquidator = address(0x11D);
    address keeper = address(0xEE9E);
    uint256 tokenId;

    uint256 constant UNIT = 1e6;

    function setUp() public {
        _deployHub();
        usd = new MockToken("tUSD", 6);
        weth = new MockToken("WETH", 18);
        tsla = new MockToken("TSLA", 18);
        wethFeed = new MockPriceFeed(address(this), 8, "WETH / USD", 2000e8);
        tslaFeed = new MockPriceFeed(address(this), 8, "TSLA / USD", 250e8);

        vm.startPrank(owner);
        hub.setAsset(address(weth), AssetClass.CANONICAL, true, address(wethFeed), 1 hours);
        hub.setAsset(address(tsla), AssetClass.STOCK, true, address(tslaFeed), 1 hours);
        hub.setRegistrar(address(this), true);
        hub.setOperator(keeper, true);
        vm.stopPrank();

        key = PoolKey(Currency.wrap(address(weth)), Currency.wrap(address(tsla)), 3000, 60, IHooks(address(0)));
        hub.registerPool(PoolId.unwrap(key.toId()), Venue.V4, address(0x4004), address(weth), address(tsla), alice);

        positions = new MockPositions();
        router = new MockRouter(address(weth));
        vault = _deployVault(usd);

        CreditManager impl = new CreditManager();
        cm = CreditManager(
            payable(
                address(
                    new ERC1967Proxy(
                        address(impl),
                        abi.encodeCall(
                            CreditManager.initialize,
                            (
                                owner,
                                IAethraHub(address(hub)),
                                IAethraPositions(address(positions)),
                                ILendingVault(address(vault)),
                                IAethraRouter(address(router))
                            )
                        )
                    )
                )
            )
        );
        vm.prank(owner);
        vault.setCreditManager(address(cm));

        // LP liquidity
        usd.mint(lp, 1_000_000 * UNIT);
        vm.startPrank(lp);
        usd.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 * UNIT, lp);
        vm.stopPrank();

        // alice: 1 WETH ($2000) + 8 TSLA ($2000) = $4000 position
        tokenId = positions.mintPosition(alice, key, 1e18, 8e18);
        vm.prank(alice);
        positions.setApprovalForAll(address(cm), true);
        vm.prank(alice);
        usd.approve(address(cm), type(uint256).max);
        vm.prank(liquidator);
        usd.approve(address(cm), type(uint256).max);
    }

    function _pledge() internal {
        vm.prank(alice);
        cm.pledge(tokenId);
    }

    function _pledgeAndBorrow(uint256 assets) internal {
        _pledge();
        vm.prank(alice);
        cm.borrow(tokenId, assets, alice);
    }

    // ------------------------------------------------------------------ pledge / release

    function test_initialState() public view {
        (uint16 ltv, uint16 lt, uint16 bonus, uint256 minDebt) = cm.riskParams();
        assertEq(ltv, 5000);
        assertEq(lt, 7000);
        assertEq(bonus, 500);
        assertEq(minDebt, 0);
        assertEq(cm.owner(), owner);
        assertTrue(cm.isSupported(tokenId));
    }

    function test_pledge() public {
        vm.expectEmit(address(cm));
        emit ICreditManager.Pledged(tokenId, alice);
        _pledge();
        assertEq(positions.ownerOf(tokenId), address(cm));
        ICreditManager.Loan memory l = cm.loan(tokenId);
        assertEq(l.owner, alice);
        assertEq(l.debtShares, 0);
        assertEq(l.openedAt, block.timestamp);
        uint256[] memory ids = cm.loansOf(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], tokenId);
        (uint256 value, uint256 maxBorrow, uint256 hf) = cm.health(tokenId);
        assertEq(value, 4000e18);
        assertEq(maxBorrow, 2000 * UNIT);
        assertEq(hf, type(uint256).max);
    }

    function test_pledgeRequiresOwnership() public {
        vm.prank(liquidator);
        vm.expectRevert(ICreditManager.NotLoanOwner.selector);
        cm.pledge(tokenId);
    }

    function test_unsupportedWhenPoolDisabled() public {
        vm.prank(owner);
        hub.setPoolEnabled(PoolId.unwrap(key.toId()), false);
        vm.prank(alice);
        vm.expectRevert(ICreditManager.UnsupportedCollateral.selector);
        cm.pledge(tokenId);
    }

    function test_unsupportedWithoutOracle() public {
        MockToken meme = new MockToken("MEME", 18);
        PoolKey memory k2 = PoolKey(Currency.wrap(address(weth)), Currency.wrap(address(meme)), 3000, 60, IHooks(address(0)));
        hub.registerPool(PoolId.unwrap(k2.toId()), Venue.V4, address(0x4004), address(weth), address(meme), alice);
        uint256 id2 = positions.mintPosition(alice, k2, 1e18, 1e18);
        assertFalse(cm.isSupported(id2));
        vm.prank(alice);
        vm.expectRevert(ICreditManager.UnsupportedCollateral.selector);
        cm.pledge(id2);
    }

    function test_unsupportedUnregisteredPool() public {
        PoolKey memory k2 = PoolKey(Currency.wrap(address(weth)), Currency.wrap(address(tsla)), 500, 10, IHooks(address(0)));
        uint256 id2 = positions.mintPosition(alice, k2, 1e18, 1e18);
        vm.prank(alice);
        vm.expectRevert(ICreditManager.UnsupportedCollateral.selector);
        cm.pledge(id2);
    }

    function test_stalePriceBlocksPledgeAndBorrow() public {
        _pledge();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vm.expectRevert(ICreditManager.UnsupportedCollateral.selector);
        cm.borrow(tokenId, 100 * UNIT, alice);
        vm.expectRevert(IAethraHub.StalePrice.selector);
        cm.health(tokenId);
        // fresh again
        wethFeed.setPrice(2000e8);
        tslaFeed.setPrice(250e8);
        vm.prank(alice);
        cm.borrow(tokenId, 100 * UNIT, alice);
    }

    function test_directTransferRejected() public {
        vm.prank(alice);
        vm.expectRevert(CreditManager.UnexpectedNft.selector);
        positions.safeTransferFrom(alice, address(cm), tokenId);
    }

    function test_releaseWithoutDebt() public {
        _pledge();
        vm.prank(liquidator);
        vm.expectRevert(ICreditManager.NotLoanOwner.selector);
        cm.release(tokenId);
        vm.prank(alice);
        cm.release(tokenId);
        assertEq(positions.ownerOf(tokenId), alice);
        assertEq(cm.loan(tokenId).owner, address(0));
        assertEq(cm.loansOf(alice).length, 0);
    }

    // ------------------------------------------------------------------ borrow / repay

    function test_borrowUpToMaxLtv() public {
        _pledge();
        vm.prank(alice);
        vm.expectRevert(ICreditManager.Unhealthy.selector);
        cm.borrow(tokenId, 2000 * UNIT + 1, alice);
        vm.expectEmit(address(cm));
        emit ICreditManager.Borrow(tokenId, alice, 2000 * UNIT);
        vm.prank(alice);
        cm.borrow(tokenId, 2000 * UNIT, alice);
        assertEq(usd.balanceOf(alice), 2000 * UNIT);
        assertEq(cm.debtOf(tokenId), 2000 * UNIT);
        (,, uint256 hf) = cm.health(tokenId);
        assertEq(hf, 1.4e18);
        vm.prank(alice);
        vm.expectRevert(ICreditManager.Unhealthy.selector);
        cm.borrow(tokenId, 1, alice);
    }

    function test_onlyOwnerBorrows() public {
        _pledge();
        vm.prank(liquidator);
        vm.expectRevert(ICreditManager.NotLoanOwner.selector);
        cm.borrow(tokenId, 1, liquidator);
    }

    function test_minDebt() public {
        vm.prank(owner);
        cm.setRiskParams(5000, 7000, 500, 100 * UNIT);
        _pledge();
        vm.prank(alice);
        vm.expectRevert(CreditManager.BelowMinDebt.selector);
        cm.borrow(tokenId, 99 * UNIT, alice);
        vm.prank(alice);
        cm.borrow(tokenId, 100 * UNIT, alice);
    }

    function test_repayAndRelease() public {
        _pledgeAndBorrow(1000 * UNIT);
        vm.prank(alice);
        vm.expectRevert(ICreditManager.OutstandingDebt.selector);
        cm.release(tokenId);

        // a third party repays part
        usd.mint(liquidator, 400 * UNIT);
        vm.prank(liquidator);
        assertEq(cm.repay(tokenId, 400 * UNIT), 400 * UNIT);
        assertApproxEqAbs(cm.debtOf(tokenId), 600 * UNIT, 1);

        // owner repays the rest, overpaying is capped
        vm.prank(alice);
        uint256 repaid = cm.repay(tokenId, type(uint256).max);
        assertApproxEqAbs(repaid, 600 * UNIT, 1);
        assertEq(cm.debtOf(tokenId), 0);
        assertEq(cm.loan(tokenId).debtShares, 0);
        assertEq(vault.totalBorrows(), 0);
        vm.prank(alice);
        cm.release(tokenId);
        assertEq(positions.ownerOf(tokenId), alice);
    }

    function test_repayUnknownLoan() public {
        vm.expectRevert(CreditManager.UnknownLoan.selector);
        cm.repay(999, 1);
    }

    function test_interestGrowsDebt() public {
        _pledgeAndBorrow(1000 * UNIT);
        vm.warp(block.timestamp + 365 days);
        wethFeed.setPrice(2000e8);
        tslaFeed.setPrice(250e8);
        uint256 debt = cm.debtOf(tokenId);
        assertGt(debt, 1000 * UNIT);
        usd.mint(alice, debt - 1000 * UNIT);
        vm.prank(alice);
        assertEq(cm.repay(tokenId, type(uint256).max), debt);
        assertEq(cm.debtOf(tokenId), 0);
        vm.prank(alice);
        cm.release(tokenId);
        assertGt(vault.totalAssets(), 1_000_000 * UNIT);
    }

    // ------------------------------------------------------------------ liquidation

    function test_liquidateHealthyReverts() public {
        _pledgeAndBorrow(2000 * UNIT);
        vm.prank(liquidator);
        vm.expectRevert(ICreditManager.Healthy.selector);
        cm.liquidate(tokenId);
    }

    function test_liquidationAfterCrash() public {
        _pledgeAndBorrow(2000 * UNIT);
        wethFeed.setPrice(1000e8);
        tslaFeed.setPrice(100e8); // value 1000 + 800 = $1800
        (uint256 value,, uint256 hf) = cm.health(tokenId);
        assertEq(value, 1800e18);
        assertLt(hf, 1e18);

        usd.mint(liquidator, 2000 * UNIT);
        vm.expectEmit(address(cm));
        emit ICreditManager.Liquidated(tokenId, liquidator, 2000 * UNIT, 1800e18);
        vm.prank(liquidator);
        cm.liquidate(tokenId);
        assertEq(positions.ownerOf(tokenId), liquidator);
        assertEq(usd.balanceOf(liquidator), 0);
        assertEq(cm.loan(tokenId).owner, address(0));
        assertEq(cm.loansOf(alice).length, 0);
        assertEq(vault.totalBorrows(), 0);
        assertEq(usd.balanceOf(alice), 2000 * UNIT); // keeps the borrowed funds, loses the NFT
    }

    function test_liquidationPaysSurplusToOwner() public {
        _pledgeAndBorrow(2000 * UNIT);
        wethFeed.setPrice(1400e8);
        tslaFeed.setPrice(175e8); // value $2800, hf = 0.98
        (,, uint256 hf) = cm.health(tokenId);
        assertEq(hf, 0.98e18);
        // liquidator pays debt + (value - debt * 1.05) = 2000 + 700
        usd.mint(liquidator, 2700 * UNIT);
        vm.prank(liquidator);
        cm.liquidate(tokenId);
        assertEq(usd.balanceOf(liquidator), 0);
        assertEq(usd.balanceOf(alice), 2700 * UNIT);
        assertEq(positions.ownerOf(tokenId), liquidator);
    }

    function test_liquidationAfterInterest() public {
        _pledgeAndBorrow(2000 * UNIT);
        // $4000 collateral, 51% threshold: healthy at 2000 debt, liquidatable once interest passes 2040
        vm.prank(owner);
        cm.setRiskParams(5000, 5100, 500, 0);
        (,, uint256 hf) = cm.health(tokenId);
        assertGt(hf, 1e18);
        // LPs withdraw most idle liquidity, so utilization (and the borrow rate) is high
        vm.prank(lp);
        vault.withdraw(997_500 * UNIT, lp, lp);
        vm.warp(block.timestamp + 365 days);
        wethFeed.setPrice(2000e8); // refresh feeds so prices are not stale
        tslaFeed.setPrice(250e8);
        (,, hf) = cm.health(tokenId);
        assertLt(hf, 1e18);
        uint256 debt = cm.debtOf(tokenId);
        assertGt(debt, 2040 * UNIT);
        usd.mint(liquidator, 10_000 * UNIT);
        vm.prank(liquidator);
        cm.liquidate(tokenId);
        assertEq(positions.ownerOf(tokenId), liquidator);
        assertEq(vault.totalBorrows(), 0);
    }

    function test_liquidateUnknown() public {
        vm.expectRevert(CreditManager.UnknownLoan.selector);
        cm.liquidate(42);
    }

    // ------------------------------------------------------------------ fees

    function test_harvestSendsFeesToOwner() public {
        _pledgeAndBorrow(500 * UNIT);
        positions.setFees(tokenId, 0.1e18, 2e18);
        vm.prank(keeper);
        (uint256 f0, uint256 f1) = cm.harvest(tokenId);
        assertEq(f0, 0.1e18);
        assertEq(f1, 2e18);
        assertEq(weth.balanceOf(alice), 0.1e18);
        assertEq(tsla.balanceOf(alice), 2e18);
        assertEq(positions.ownerOf(tokenId), address(cm));
    }

    function _routeTo(address tokenIn) internal view returns (IAethraRouter.Hop[] memory r) {
        r = new IAethraRouter.Hop[](1);
        r[0] = IAethraRouter.Hop(Venue.V4, address(0), tokenIn, address(usd), abi.encode(key));
    }

    function test_autoRepayFromFees() public {
        _pledgeAndBorrow(300 * UNIT);
        router.setRate(address(weth), address(usd), 2000 * UNIT); // 1 WETH -> 2000 USD
        router.setRate(address(tsla), address(usd), 250 * UNIT);
        positions.setFees(tokenId, 0.1e18, 1e18); // $200 + $250

        vm.prank(liquidator);
        vm.expectRevert(CreditManager.NotAuthorized.selector);
        cm.autoRepayFromFees(tokenId, _routeTo(address(weth)), _routeTo(address(tsla)), 0);

        vm.prank(keeper);
        vm.expectRevert(CreditManager.Slippage.selector);
        cm.autoRepayFromFees(tokenId, _routeTo(address(weth)), _routeTo(address(tsla)), 451 * UNIT);

        vm.prank(keeper);
        uint256 repaid = cm.autoRepayFromFees(tokenId, _routeTo(address(weth)), _routeTo(address(tsla)), 450 * UNIT);
        assertEq(repaid, 300 * UNIT);
        assertEq(cm.debtOf(tokenId), 0);
        assertEq(usd.balanceOf(alice), 300 * UNIT + 150 * UNIT); // borrowed + refund
    }

    function test_autoRepayPartialAndEmptyRoute() public {
        _pledgeAndBorrow(1000 * UNIT);
        router.setRate(address(weth), address(usd), 2000 * UNIT);
        positions.setFees(tokenId, 0.1e18, 1e18);
        IAethraRouter.Hop[] memory none;
        vm.prank(alice);
        uint256 repaid = cm.autoRepayFromFees(tokenId, _routeTo(address(weth)), none, 0);
        assertEq(repaid, 200 * UNIT);
        assertApproxEqAbs(cm.debtOf(tokenId), 800 * UNIT, 1);
        assertEq(tsla.balanceOf(alice), 1e18); // no route: fee forwarded to owner
    }

    function test_autoRepayBadRoute() public {
        _pledgeAndBorrow(1000 * UNIT);
        positions.setFees(tokenId, 0.1e18, 0);
        vm.prank(alice);
        vm.expectRevert(CreditManager.BadRoute.selector);
        cm.autoRepayFromFees(tokenId, _routeTo(address(tsla)), new IAethraRouter.Hop[](0), 0);
        IAethraRouter.Hop[] memory r = new IAethraRouter.Hop[](1);
        r[0] = IAethraRouter.Hop(Venue.V4, address(0), address(weth), address(tsla), "");
        vm.prank(alice);
        vm.expectRevert(CreditManager.BadRoute.selector);
        cm.autoRepayFromFees(tokenId, r, new IAethraRouter.Hop[](0), 0);
    }

    // ------------------------------------------------------------------ admin / upgrade

    function test_riskParamValidation() public {
        vm.expectRevert();
        cm.setRiskParams(5000, 7000, 500, 0);
        vm.startPrank(owner);
        vm.expectRevert(CreditManager.InvalidParams.selector);
        cm.setRiskParams(0, 7000, 500, 0);
        vm.expectRevert(CreditManager.InvalidParams.selector);
        cm.setRiskParams(8000, 7000, 500, 0);
        vm.expectRevert(CreditManager.InvalidParams.selector);
        cm.setRiskParams(5000, 10_000, 500, 0);
        vm.expectRevert(CreditManager.InvalidParams.selector);
        cm.setRiskParams(5000, 7000, 2001, 0);
        cm.setRiskParams(6000, 8000, 800, 1);
        vm.stopPrank();
    }

    function test_upgradeKeepsLoans() public {
        _pledgeAndBorrow(1000 * UNIT);
        CreditManagerV2 v2 = new CreditManagerV2();
        vm.expectRevert();
        cm.upgradeToAndCall(address(v2), "");
        vm.prank(owner);
        cm.upgradeToAndCall(address(v2), "");
        assertEq(CreditManagerV2(payable(address(cm))).version(), 2);
        assertEq(cm.loan(tokenId).owner, alice);
        assertEq(cm.debtOf(tokenId), 1000 * UNIT);
        assertEq(cm.loansOf(alice).length, 1);
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_borrowLimitedByLtv(uint128 amt0, uint128 amt1, uint256 borrowAmt) public {
        uint256 a0 = bound(amt0, 0, 100e18);
        uint256 a1 = bound(amt1, 0, 1000e18);
        positions.setAmounts(tokenId, a0, a1);
        _pledge();
        uint256 maxBorrow = (a0 * 2000 + a1 * 250) / 1e12 / 2; // USD 1e18 -> 6 decimals, 50% LTV
        uint256 b = bound(borrowAmt, 1, 1_000_000 * UNIT);
        vm.prank(alice);
        if (b > maxBorrow) {
            vm.expectRevert(ICreditManager.Unhealthy.selector);
            cm.borrow(tokenId, b, alice);
        } else {
            cm.borrow(tokenId, b, alice);
            assertEq(cm.debtOf(tokenId), b);
            (,, uint256 hf) = cm.health(tokenId);
            assertGe(hf, 1.4e18 - 1);
        }
    }

    function testFuzz_liquidatableIffUnhealthy(uint64 newWethPrice, uint64 newTslaPrice, uint256 borrowAmt) public {
        uint256 b = bound(borrowAmt, 1 * UNIT, 2000 * UNIT);
        _pledgeAndBorrow(b);
        wethFeed.setPrice(int256(bound(newWethPrice, 1e8, 4000e8)));
        tslaFeed.setPrice(int256(bound(newTslaPrice, 1e8, 500e8)));
        (uint256 value,, uint256 hf) = cm.health(tokenId);
        usd.mint(liquidator, 10_000 * UNIT);
        if (hf >= 1e18) {
            vm.prank(liquidator);
            vm.expectRevert(ICreditManager.Healthy.selector);
            cm.liquidate(tokenId);
        } else {
            uint256 before = usd.balanceOf(liquidator);
            vm.prank(liquidator);
            cm.liquidate(tokenId);
            uint256 paid = before - usd.balanceOf(liquidator);
            assertGe(paid, b);
            // above debt * (1 + bonus) the liquidator pays the collateral value minus its bonus; the rest goes to the owner
            uint256 valueAsset = value / 1e12;
            if (valueAsset > b * 10_500 / 10_000) assertApproxEqAbs(paid, valueAsset - b * 500 / 10_000, 1);
            assertEq(positions.ownerOf(tokenId), liquidator);
        }
    }
}
