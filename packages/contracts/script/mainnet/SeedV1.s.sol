// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {AethraPositions} from "../../src/periphery/AethraPositions.sol";
import {IAethraPositions} from "../../src/interfaces/IAethraPeriphery.sol";

interface IWETH9 {
    function deposit() external payable;
}

/// @notice v1.0 launch: opens the WETH/USDG v4 pool behind the Aethra hook at the market price and seeds it with a
///         full-range position owned by the deployer.
/// @dev SEED_ETH (wei) is wrapped and paired with SEED_USDG (6 decimals). PRICE_USDG_PER_ETH (6 decimals, e.g.
///      2242580000 for $2,242.58) sets the opening price; the script refuses a USDG amount more than 5% away from it.
///      If the pool already exists (a second run), the position is added at the pool's current price instead.
contract SeedV1 is Script {
    using StateLibrary for IPoolManager;

    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    IPoolManager internal constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    int24 internal constant SPACING = 10;

    function run() external returns (bytes32 poolId, uint256 tokenId) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/mainnet.json"));
        address weth = vm.parseJsonAddress(json, ".weth");
        address usdg = vm.parseJsonAddress(json, ".tokens.USDG.address");
        address hook = vm.parseJsonAddress(json, ".hook");
        AethraPositions positions = AethraPositions(vm.parseJsonAddress(json, ".positions"));

        uint256 seedEth = vm.envUint("SEED_ETH");
        uint256 seedUsdg = vm.envUint("SEED_USDG");
        uint256 price6 = vm.envUint("PRICE_USDG_PER_ETH");
        // the paired amounts must agree with the opening price within 5%
        uint256 implied = seedEth * price6 / 1e18;
        require(seedUsdg * 100 >= implied * 95 && seedUsdg * 100 <= implied * 105, "SeedV1: USDG amount off the price");

        require(weth < usdg, "SeedV1: expected WETH to sort before USDG");
        PoolKey memory key =
            PoolKey(Currency.wrap(weth), Currency.wrap(usdg), LPFeeLibrary.DYNAMIC_FEE_FLAG, SPACING, IHooks(hook));
        poolId = PoolId.unwrap(key.toId());

        vm.startBroadcast(DEPLOYER);
        (uint160 sqrtP,,,) = PM.getSlot0(key.toId());
        if (sqrtP == 0) {
            sqrtP = _sqrtPriceX96(price6);
            PM.initialize(key, sqrtP);
        }
        IWETH9(weth).deposit{value: seedEth}();
        IERC20(weth).approve(address(positions), seedEth);
        IERC20(usdg).approve(address(positions), seedUsdg);
        int24 lo = TickMath.minUsableTick(SPACING);
        int24 hi = TickMath.maxUsableTick(SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(lo), TickMath.getSqrtPriceAtTick(hi), seedEth, seedUsdg
        );
        (tokenId,,) = positions.mint(
            IAethraPositions.MintParams(key, lo, hi, liq, seedEth, seedUsdg, DEPLOYER, block.timestamp + 30 minutes)
        );
        vm.stopBroadcast();

        console2.log("pool id");
        console2.logBytes32(poolId);
        console2.log("position", tokenId);
    }

    /// @dev sqrt(price) in Q64.96 where price = USDG raw units per WETH raw unit = price6 / 1e18.
    function _sqrtPriceX96(uint256 price6) internal pure returns (uint160) {
        // price * 2^192 = price6 * 2^192 / 1e18; computed as (price6 << 96) / 1e9 then sqrt of that times 2^96 / 1e9
        uint256 ratioX192 = (price6 << 192) / 1e18;
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
