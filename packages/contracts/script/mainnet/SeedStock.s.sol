// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {AethraPositions} from "../../src/periphery/AethraPositions.sol";
import {IAethraPositions} from "../../src/interfaces/IAethraPeriphery.sol";

interface IWETH9s {
    function deposit() external payable;
}

interface IHubPrice {
    function getPrice(address token) external view returns (uint256 priceE18);
}

/// @notice Minimal exact-input swapper for any v4 pool (native or ERC20 input). The Aethra router handles ERC20 hops
///         only, and the deep ETH/USDG pool uses native ETH. Holds no funds between calls.
contract V4Swapper is IUnlockCallback {
    IPoolManager public immutable pm;

    struct Req {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address payer;
        address to;
    }

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, address to) external payable returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(Req(key, zeroForOne, amountIn, msg.sender, to))), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "V4Swapper: not the pool manager");
        Req memory q = abi.decode(data, (Req));
        BalanceDelta d = pm.swap(
            q.key,
            IPoolManager.SwapParams(
                q.zeroForOne, -int256(q.amountIn), q.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        (Currency cin, Currency cout) =
            q.zeroForOne ? (q.key.currency0, q.key.currency1) : (q.key.currency1, q.key.currency0);
        (int128 din, int128 dout) = q.zeroForOne ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 pay = uint256(uint128(-din));
        uint256 got = uint256(uint128(dout));
        if (Currency.unwrap(cin) == address(0)) {
            pm.settle{value: pay}();
        } else {
            pm.sync(cin);
            require(IERC20(Currency.unwrap(cin)).transferFrom(q.payer, address(pm), pay), "V4Swapper: pull failed");
            pm.settle();
        }
        pm.take(cout, q.to, got);
        return abi.encode(got);
    }
}

/// @notice Opens three more Aethra pools with minimal funds, all behind the Aethra hook in ORACLE mode (stock assets):
///         TSLA/WETH, TSLA/USDG and NVDA/WETH, full range, owned by the deployer.
/// @dev TSLA has no ETH or WETH venue, so the script buys it: ETH -> USDG through the deep native ETH/USDG pool, then
///      USDG -> TSLA through the plain TSLA/USDG 0.3% pool (both external Uniswap v4 pools; ids are checked). NVDA has
///      no liquid venue, so the NVDA/WETH pool uses whatever NVDA the deployer already holds. Opening prices come from
///      the hub oracle; the hook rejects an initialize that deviates from it or uses a stale feed (stock feeds go stale
///      24h after their last update, so run this while the market is open or just after).
///      SIDE_USD_E6: value of each side of the TSLA pools in USD with 6 decimals (default 100000 = $0.10).
///      ETH_FOR_USDG: wei swapped to USDG to fund the TSLA purchase and the TSLA/USDG pool (default 0.00016 ETH).
contract SeedStock is Script {
    using StateLibrary for IPoolManager;

    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    int24 internal constant SPACING = 10;
    bytes32 internal constant ETH_USDG_ID = 0xa791e5169faf703c0b63fd9552c33ec1128a773a00f5dc33a640da62a022cd35;
    bytes32 internal constant TSLA_USDG_ID = 0x8517f8071ae5b831b738052f12125e8e3d6c158b78728aa44ce3b25e5104d32e;

    struct Env {
        address weth;
        address usdg;
        address tsla;
        address nvda;
        address hook;
        IHubPrice hub;
        AethraPositions positions;
    }

    function run() external {
        Env memory e = _env();
        uint256 sideUsd = vm.envOr("SIDE_USD_E6", uint256(100_000));
        uint256 ethForUsdg = vm.envOr("ETH_FOR_USDG", uint256(160_000_000_000_000));

        uint256 pWeth = e.hub.getPrice(e.weth);
        uint256 pTsla = e.hub.getPrice(e.tsla);
        uint256 pNvda = e.hub.getPrice(e.nvda);
        uint256 pUsdg = e.hub.getPrice(e.usdg);

        uint256 tslaSide = sideUsd * 1e12 * 1e18 / pTsla; // 18 decimals
        uint256 usdgSide = sideUsd * 1e12 * 1e18 / pUsdg / 1e12; // 6 decimals
        uint256 wethA = sideUsd * 1e12 * 1e18 / pWeth;
        uint256 nvdaBal = IERC20(e.nvda).balanceOf(DEPLOYER);
        uint256 wethC = nvdaBal * pNvda / pWeth;
        uint256 tslaBuyUsdg = 2 * sideUsd * 103 / 100; // USDG (6 decimals) spent on TSLA: both TSLA sides plus 3% for fees

        PoolKey memory ethUsdg = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(e.usdg), LPFeeLibrary.DYNAMIC_FEE_FLAG, 1, IHooks(0x987E330F00B79864a07FE81dFaC344D0078ABCC0)
        );
        PoolKey memory tslaUsdgExt = PoolKey(Currency.wrap(e.tsla), Currency.wrap(e.usdg), 3000, 60, IHooks(address(0)));
        require(PoolId.unwrap(ethUsdg.toId()) == ETH_USDG_ID, "SeedStock: ETH/USDG key mismatch");
        require(PoolId.unwrap(tslaUsdgExt.toId()) == TSLA_USDG_ID, "SeedStock: TSLA/USDG key mismatch");

        vm.startBroadcast(DEPLOYER);

        // 1. buy TSLA: ETH -> USDG -> TSLA
        V4Swapper swapper = new V4Swapper(PM);
        swapper.swap{value: ethForUsdg}(ethUsdg, true, ethForUsdg, DEPLOYER);
        require(
            IERC20(e.usdg).balanceOf(DEPLOYER) >= tslaBuyUsdg + usdgSide, "SeedStock: not enough USDG, raise ETH_FOR_USDG"
        );
        IERC20(e.usdg).approve(address(swapper), tslaBuyUsdg);
        swapper.swap(tslaUsdgExt, false, tslaBuyUsdg, DEPLOYER);
        uint256 tslaBal = IERC20(e.tsla).balanceOf(DEPLOYER);
        require(tslaBal >= 2 * tslaSide * 99 / 100, "SeedStock: bought too little TSLA");
        uint256 tslaEach = tslaBal / 2 < tslaSide ? tslaBal / 2 : tslaSide;

        // 2. wrap and approve
        IWETH9s(e.weth).deposit{value: wethA + wethC}();
        IERC20(e.weth).approve(address(e.positions), wethA + wethC);
        IERC20(e.tsla).approve(address(e.positions), 2 * tslaEach);
        IERC20(e.usdg).approve(address(e.positions), usdgSide);
        IERC20(e.nvda).approve(address(e.positions), nvdaBal);

        // 3. open and seed the three pools
        _open(e, e.weth, e.tsla, wethA, tslaEach, 18, 18);
        _open(e, e.tsla, e.usdg, tslaEach, usdgSide, 18, 6);
        _open(e, e.weth, e.nvda, wethC, nvdaBal, 18, 18);

        vm.stopBroadcast();
    }

    function _env() internal view returns (Env memory e) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/mainnet.json"));
        e.weth = vm.parseJsonAddress(json, ".weth");
        e.usdg = vm.parseJsonAddress(json, ".tokens.USDG.address");
        e.tsla = vm.parseJsonAddress(json, ".tokens.TSLA.address");
        e.nvda = vm.parseJsonAddress(json, ".tokens.NVDA.address");
        e.hook = vm.parseJsonAddress(json, ".hook");
        e.hub = IHubPrice(vm.parseJsonAddress(json, ".hub"));
        e.positions = AethraPositions(vm.parseJsonAddress(json, ".positions"));
    }

    function _open(Env memory e, address t0, address t1, uint256 amt0, uint256 amt1, uint8 d0, uint8 d1) internal {
        require(t0 < t1, "SeedStock: token order");
        PoolKey memory key =
            PoolKey(Currency.wrap(t0), Currency.wrap(t1), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(e.hook));
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        if (sqrtP == 0) {
            sqrtP = _sqrtPrice(e.hub.getPrice(t0), e.hub.getPrice(t1), d0, d1);
            PM.initialize(key, sqrtP);
        }
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), amt0, amt1
        );
        (uint256 tokenId,,) = e.positions.mint(
            IAethraPositions.MintParams(key, lo, hi, liq, amt0, amt1, DEPLOYER, block.timestamp + 30 minutes)
        );
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("position", tokenId);
    }

    /// @dev sqrt(token1 raw per token0 raw) in Q64.96 from the two USD prices (18 decimals) and the token decimals.
    function _sqrtPrice(uint256 p0, uint256 p1, uint8 d0, uint8 d1) internal pure returns (uint160) {
        uint256 ratioX192 = FullMath.mulDiv(p0 * 10 ** d1, 1 << 192, p1 * 10 ** d0);
        return uint160(_sqrt(ratioX192));
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
}
