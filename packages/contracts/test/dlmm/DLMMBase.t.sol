// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {IDLMMFactory} from "../../src/interfaces/IAethraPools.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {DLMMFactory} from "../../src/dlmm/DLMMFactory.sol";
import {DLMMLimitOrders} from "../../src/dlmm/DLMMLimitOrders.sol";

contract TestToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory sym, uint8 dec_) ERC20(sym, sym) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

abstract contract DLMMBase is Test {
    AethraHub hub;
    UpgradeableBeacon beacon;
    DLMMFactory factory;
    DLMMLimitOrders orders;
    TestToken token0;
    TestToken token1;
    DLMMPool pool;

    address owner = address(0xA11CE);
    address buyback = address(0xB0B);
    address lp = address(0x1111);
    address trader = address(0x2222);

    uint16 constant STEP = 25;
    uint24 constant BASE_FEE = 3000; // 0.30%
    uint24 constant MAX_FEE = 50_000;

    function setUp() public virtual {
        hub = AethraHub(
            address(new ERC1967Proxy(address(new AethraHub()), abi.encodeCall(AethraHub.initialize, (owner))))
        );
        beacon = new UpgradeableBeacon(address(new DLMMPool()), owner);
        factory = DLMMFactory(
            address(
                new ERC1967Proxy(
                    address(new DLMMFactory()), abi.encodeCall(DLMMFactory.initialize, (owner, address(hub), address(beacon)))
                )
            )
        );
        orders = DLMMLimitOrders(
            address(
                new ERC1967Proxy(
                    address(new DLMMLimitOrders()), abi.encodeCall(DLMMLimitOrders.initialize, (owner, address(factory)))
                )
            )
        );
        vm.startPrank(owner);
        hub.setRegistrar(address(factory), true);
        hub.setFeeConfig(buyback, address(0xC0FFEE), 2000); // 20% of fees to protocol
        vm.stopPrank();

        TestToken a = new TestToken("AAA", 18);
        TestToken b = new TestToken("BBB", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = _createPool(STEP, 0, BASE_FEE, MAX_FEE);

        _fund(lp, 1e30);
        _fund(trader, 1e30);
        _fund(address(this), 1e30);
    }

    function _createPool(uint16 step, int24 active, uint24 base, uint24 max) internal returns (DLMMPool) {
        return DLMMPool(
            factory.createPool(
                IDLMMFactory.CreateParams({
                    tokenA: address(token0),
                    tokenB: address(token1),
                    binStepBps: step,
                    activeId: active,
                    baseFee: base,
                    maxFee: max
                })
            )
        );
    }

    function _fund(address who, uint256 amount) internal {
        token0.mint(who, amount);
        token1.mint(who, amount);
        vm.startPrank(who);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        token0.approve(address(orders), type(uint256).max);
        token1.approve(address(orders), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Spread liquidity: `perBin` token1 in each of `n` bins below active, token0 in `n` bins above,
    ///      and both in the active bin.
    function _seed(DLMMPool p, address who, int24 n, uint256 perBin) internal returns (uint256[] memory shares) {
        int24 active = p.activeId();
        uint256 len = uint256(int256(n)) * 2 + 1;
        int24[] memory ids = new int24[](len);
        uint256[] memory a0 = new uint256[](len);
        uint256[] memory a1 = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            int24 id = active - n + int24(int256(i));
            ids[i] = id;
            if (id >= active) a0[i] = perBin;
            if (id <= active) a1[i] = perBin;
        }
        vm.prank(who);
        shares = p.addLiquidity(ids, a0, a1, who, block.timestamp);
    }

    function _one(int24 id) internal pure returns (int24[] memory a) {
        a = new int24[](1);
        a[0] = id;
    }

    function _oneU(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    function _add(DLMMPool p, address who, int24 id, uint256 x, uint256 y) internal returns (uint256) {
        vm.prank(who);
        return p.addLiquidity(_one(id), _oneU(x), _oneU(y), who, block.timestamp)[0];
    }

    function _swap(DLMMPool p, address who, bool zeroForOne, uint256 amountIn) internal returns (uint256) {
        vm.prank(who);
        return p.swapExactInput(zeroForOne ? address(token0) : address(token1), amountIn, 0, who, block.timestamp);
    }
}
