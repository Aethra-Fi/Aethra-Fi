// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {AethraHub} from "../src/core/AethraHub.sol";
import {AethraHook} from "../src/hooks/AethraHook.sol";
import {AethraPositions} from "../src/periphery/AethraPositions.sol";
import {AethraRouter} from "../src/periphery/AethraRouter.sol";

/// @notice Deploys the Aethra Fi protocol (proxies + implementations) and writes addresses to the SDK.
/// @dev Usage (see scripts/local-deploy.sh and docs/BLOCKERS.md):
///      NETWORK=local|testnet|mainnet forge script script/Deploy.s.sol --rpc-url <net> --sender $DEPLOYER_ADDRESS ...
///      Mainnet is dry-run only (no --broadcast) and never writes addresses.
contract Deploy is Script {
    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    struct Core {
        address hub;
        address positions;
        address router;
        address hook;
        address hubImpl;
        address positionsImpl;
        address routerImpl;
        address hookImpl;
    }

    string internal network;
    string internal addressesPath;

    function run() external returns (Core memory c) {
        network = vm.envOr("NETWORK", string("local"));
        addressesPath = string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json");
        require(msg.sender == DEPLOYER, "Deploy: sender must be the Aethra deployer");
        require(POOL_MANAGER.code.length > 0, "Deploy: PoolManager missing on this chain");

        address weth = vm.parseJsonAddress(vm.readFile(addressesPath), ".weth");
        require(weth.code.length > 0, "Deploy: WETH missing on this chain");

        vm.startBroadcast();
        c = _deployCore(weth);
        vm.stopBroadcast();

        _log(c);
        if (_shouldWrite()) _write(c);
    }

    function _deployCore(address weth) internal returns (Core memory c) {
        IPoolManager pm = IPoolManager(POOL_MANAGER);

        c.hubImpl = address(new AethraHub());
        c.hub = address(new ERC1967Proxy(c.hubImpl, abi.encodeCall(AethraHub.initialize, (DEPLOYER))));

        c.positionsImpl = address(new AethraPositions(pm));
        c.positions =
            address(new ERC1967Proxy(c.positionsImpl, abi.encodeCall(AethraPositions.initialize, (DEPLOYER))));

        c.routerImpl = address(new AethraRouter(pm, weth));
        c.router = address(
            new ERC1967Proxy(c.routerImpl, abi.encodeCall(AethraRouter.initialize, (DEPLOYER, AethraHub(c.hub))))
        );

        c.hookImpl = address(new AethraHook(pm));
        bytes memory hookInit = abi.encodeCall(AethraHook.initialize, (DEPLOYER, AethraHub(c.hub), c.positions));
        (bytes32 salt, address predicted) = _mineHook(c.hookImpl, hookInit);
        c.hook = address(new ERC1967Proxy{salt: salt}(c.hookImpl, hookInit));
        require(c.hook == predicted, "Deploy: hook address mismatch");

        AethraHub hub = AethraHub(c.hub);
        hub.setRegistrar(c.hook, true);
        hub.setFeeConfig(address(0), DEPLOYER, 2000); // buyback wired once deployed
    }

    /// @dev Find a CREATE2 salt so the hook proxy's address encodes exactly HOOK_FLAGS in its low 14 bits.
    function _mineHook(address impl, bytes memory initData) internal view returns (bytes32, address) {
        bytes32 initHash = keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData)));
        uint160 flags = AethraHook(impl).HOOK_FLAGS();
        for (uint256 i; i < 2_000_000; i++) {
            bytes32 salt = bytes32(i);
            address a = vm.computeCreate2Address(salt, initHash, CREATE2_DEPLOYER);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags && a.code.length == 0) return (salt, a);
        }
        revert("Deploy: no hook salt found");
    }

    function _shouldWrite() internal view returns (bool) {
        return keccak256(bytes(network)) != keccak256("mainnet") && vm.envOr("WRITE_ADDRESSES", true);
    }

    function _write(Core memory c) internal {
        _put(".hub", c.hub);
        _put(".hook", c.hook);
        _put(".router", c.router);
        _put(".positions", c.positions);
        vm.writeJson(vm.toString(block.number), addressesPath, ".startBlock");
    }

    function _put(string memory key, address a) internal {
        vm.writeJson(string.concat('"', vm.toString(a), '"'), addressesPath, key);
    }

    function _log(Core memory c) internal pure {
        console2.log("hub        ", c.hub);
        console2.log("positions  ", c.positions);
        console2.log("router     ", c.router);
        console2.log("hook       ", c.hook);
    }
}
