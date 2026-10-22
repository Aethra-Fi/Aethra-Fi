// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {AethraHook} from "../../src/hooks/AethraHook.sol";
import {AethraPositions} from "../../src/periphery/AethraPositions.sol";
import {AethraRouter} from "../../src/periphery/AethraRouter.sol";
import {IAethraPositions, IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {AssetClass, Venue} from "../../src/interfaces/IAethraHub.sol";
import {MockPriceFeed} from "../../src/mocks/MockPriceFeed.sol";

contract TestToken is ERC20 {
    uint8 internal immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TestWETH is TestToken {
    constructor() TestToken("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}

/// @notice Deploys the real v4 PoolManager plus Aethra hub, hook (at a flag-encoded address), positions and router.
abstract contract AethraFixture is Test {
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buybackSink = makeAddr("buyback");

    PoolManager internal manager;
    AethraHub internal hub;
    AethraHook internal hook;
    AethraPositions internal positions;
    AethraRouter internal router;
    TestWETH internal weth;
    TestToken internal usd;
    TestToken internal stock;

    function setUpAethra() internal {
        manager = new PoolManager(address(this));
        weth = new TestWETH();
        usd = new TestToken("Test USD", "tUSD", 6);
        stock = new TestToken("Test Tesla", "tTSLA", 18);

        hub = AethraHub(address(new ERC1967Proxy(address(new AethraHub()), abi.encodeCall(AethraHub.initialize, (owner)))));
        positions = AethraPositions(
            address(
                new ERC1967Proxy(
                    address(new AethraPositions(manager)), abi.encodeCall(AethraPositions.initialize, (owner))
                )
            )
        );
        router = AethraRouter(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new AethraRouter(manager, address(weth))),
                        abi.encodeCall(AethraRouter.initialize, (owner, hub))
                    )
                )
            )
        );

        // hook proxy must live at an address whose low 14 bits equal the permission flags
        AethraHook hookImpl = new AethraHook(manager);
        address hookAddr = address(uint160(0xAE7A0000) << 128 | uint160(hookImpl.HOOK_FLAGS()));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(address(hookImpl), abi.encodeCall(AethraHook.initialize, (owner, hub, address(positions)))),
            hookAddr
        );
        hook = AethraHook(hookAddr);

        vm.startPrank(owner);
        hub.setRegistrar(address(hook), true);
        hub.setFeeConfig(buybackSink, makeAddr("treasury"), 2000); // 20% of fees to buyback
        hub.setAsset(address(weth), AssetClass.CANONICAL, true, address(new MockPriceFeed(owner, 8, "ETH/USD", 2400e8)), 1 days);
        hub.setAsset(address(usd), AssetClass.CANONICAL, true, address(new MockPriceFeed(owner, 8, "USD/USD", 1e8)), 1 days);
        hub.setAsset(address(stock), AssetClass.STOCK, true, address(new MockPriceFeed(owner, 8, "TSLA/USD", 250e8)), 1 days);
        vm.stopPrank();

        address[3] memory users = [alice, bob, address(this)];
        for (uint256 i; i < users.length; i++) {
            weth.mint(users[i], 1_000_000e18);
            usd.mint(users[i], 1_000_000_000e6);
            stock.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            weth.approve(address(positions), type(uint256).max);
            usd.approve(address(positions), type(uint256).max);
            stock.approve(address(positions), type(uint256).max);
            weth.approve(address(router), type(uint256).max);
            usd.approve(address(router), type(uint256).max);
            stock.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function keyFor(address a, address b, int24 spacing) internal view returns (PoolKey memory key) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(address(hook)));
    }

    /// @dev sqrtPriceX96 for a human price (token1 per token0) given decimals.
    function sqrtPriceFor(uint256 priceE18, uint8 dec0, uint8 dec1) internal pure returns (uint160) {
        // raw = price * 10^dec1 / 10^dec0 ; sqrtP = sqrt(raw) * 2^96
        uint256 rawX192 = priceE18 * (10 ** dec1) * (1 << 96) / (10 ** dec0) / 1e18 * (1 << 96);
        return uint160(_sqrt(rawX192));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    function fullRange(int24 spacing) internal pure returns (int24 lo, int24 hi) {
        lo = TickMath.minUsableTick(spacing);
        hi = TickMath.maxUsableTick(spacing);
    }

    function mintFullRange(address who, PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId, uint128 liquidity)
    {
        (int24 lo, int24 hi) = fullRange(key.tickSpacing);
        (uint160 sqrtP,,,) = _slot0(key);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), amount0, amount1
        );
        vm.prank(who);
        (tokenId,,) = positions.mint(
            IAethraPositions.MintParams(key, lo, hi, liquidity, amount0 + 1, amount1 + 1, who, block.timestamp)
        );
    }

    function v4Hop(PoolKey memory key, address tokenIn, address tokenOut) internal pure returns (IAethraRouter.Hop memory) {
        return IAethraRouter.Hop(Venue.V4, address(0), tokenIn, tokenOut, abi.encode(key));
    }

    function _slot0(PoolKey memory key) internal view returns (uint160, int24, uint24, uint24) {
        return StateLibrary.getSlot0(manager, PoolIdLibrary.toId(key));
    }
}
