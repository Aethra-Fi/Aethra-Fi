// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Upgrades, Options} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {AethraHook} from "../../src/hooks/AethraHook.sol";
import {AethraPositions} from "../../src/periphery/AethraPositions.sol";
import {AethraRouter} from "../../src/periphery/AethraRouter.sol";
import {IAethraHub} from "../../src/interfaces/IAethraHub.sol";
import {DLMMFactory} from "../../src/dlmm/DLMMFactory.sol";
import {DLMMLimitOrders} from "../../src/dlmm/DLMMLimitOrders.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {DAMMFactory} from "../../src/damm/DAMMFactory.sol";
import {DAMMPool} from "../../src/damm/DAMMPool.sol";
import {AethraLaunchpad} from "../../src/launchpad/AethraLaunchpad.sol";
import {AethraBuyback} from "../../src/buyback/AethraBuyback.sol";
import {LendingVault} from "../../src/credit/LendingVault.sol";
import {CreditManager} from "../../src/credit/CreditManager.sol";

/// @notice Validates and rolls out an implementation upgrade for one Aethra proxy or pool beacon.
///
/// 1. Validates the new implementation with OpenZeppelin Upgrades: storage layout against the code that is deployed
///    today, plus upgrade-safety rules. The deployed code is a saved build: `scripts/snapshot-build.sh <git-ref> <name>`
///    (REFERENCE_BUILD_INFO=upgrades/<name>, REFERENCE_NAME=<name>).
/// 2. Deploys the new implementation.
/// 3. Upgrades the proxy when the broadcaster owns it (`DIRECT=true`, testnet), otherwise prints the calldata that the
///    owner (the Safe) must send.
///
/// Required env: NETWORK (local|testnet|mainnet), CONTRACT (one name, or several separated by commas), REFERENCE_BUILD_INFO (directory) and REFERENCE_NAME (the
/// directory's name; the reference contract is "<REFERENCE_NAME>:<ContractName>").
/// CONTRACT is one of: hub hook router positions dlmmFactory dlmmLimitOrders dlmmPool dammFactory dammPool launchpad
/// buyback lendingVault creditManager. `dlmmPool` and `dammPool` upgrade the pool beacon read from the factory.
/// Optional: PROXY overrides the address read from packages/sdk/src/addresses/<network>.json.
///
/// Usage (see docs/BLOCKERS.md B10 for the exact commands). Run it with FOUNDRY_PROFILE=upgrade FOUNDRY_OUT=out-upgrade:
///   forge script script/upgrade/Upgrade.s.sol:Upgrade --rpc-url <net> --account deployer --sender $DEPLOYER_ADDRESS [--broadcast]
contract Upgrade is Script {
    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct Target {
        string artifact; // "AethraRouter.sol:AethraRouter"
        address proxy; // UUPS proxy, or the pool beacon for dlmmPool / dammPool
        bool beacon;
        bool immutables; // constructor sets immutables (fixed per implementation, so allowed)
    }

    function run() external {
        string memory network = vm.envString("NETWORK");
        require(block.chainid == _chainIdOf(network), "Upgrade: RPC chain does not match NETWORK");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json"));
        string[] memory names = vm.split(vm.envString("CONTRACT"), ",");
        address proxyOverride = vm.envOr("PROXY", address(0));
        require(proxyOverride == address(0) || names.length == 1, "Upgrade: PROXY needs a single CONTRACT");
        for (uint256 i; i < names.length; i++) {
            _upgrade(names[i], json, proxyOverride);
        }
    }

    function _upgrade(string memory name, string memory json, address proxyOverride) internal {
        console2.log("==", name);
        Target memory t = _target(name, json);
        if (proxyOverride != address(0)) t.proxy = proxyOverride;
        require(t.proxy != address(0) && t.proxy.code.length > 0, "Upgrade: target is not deployed on this chain");

        _validate(t);

        vm.startBroadcast();
        address impl = _deployImplementation(name, json);
        vm.stopBroadcast();
        console2.log("new implementation", impl);

        bytes memory callData = t.beacon
            ? abi.encodeCall(UpgradeableBeacon.upgradeTo, (impl))
            : abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, ""));
        address owner = t.beacon ? UpgradeableBeacon(t.proxy).owner() : OwnableUpgradeable(t.proxy).owner();
        console2.log("owner of target   ", owner);

        if (vm.envOr("DIRECT", false)) {
            require(owner == msg.sender, "Upgrade: DIRECT needs the broadcaster to be the owner");
            vm.startBroadcast();
            (bool ok,) = t.proxy.call(callData);
            require(ok, "Upgrade: upgrade call failed");
            vm.stopBroadcast();
            address live = t.beacon
                ? UpgradeableBeacon(t.proxy).implementation()
                : address(uint160(uint256(vm.load(t.proxy, IMPLEMENTATION_SLOT))));
            require(live == impl, "Upgrade: implementation not updated");
            console2.log("upgraded", t.proxy);
        } else {
            console2.log("Send this transaction from the owner (Safe):");
            console2.log("  to      ", t.proxy);
            console2.log("  value    0");
            console2.logBytes(callData);
        }
    }

    function _chainIdOf(string memory network) internal pure returns (uint256) {
        bytes32 h = keccak256(bytes(network));
        if (h == keccak256("mainnet")) return 4663;
        if (h == keccak256("testnet")) return 46630;
        if (h == keccak256("local")) return 31337;
        revert("Upgrade: unknown NETWORK");
    }

    function _validate(Target memory t) internal {
        Options memory opts;
        string memory refName = vm.envString("REFERENCE_NAME");
        opts.referenceBuildInfoDir = vm.envString("REFERENCE_BUILD_INFO");
        // "AethraRouter.sol:AethraRouter" -> "<refName>:AethraRouter"
        opts.referenceContract = string.concat(refName, ":", _contractOf(t.artifact));
        // Every implementation here has a constructor that only sets immutables and calls _disableInitializers
        // (reviewed by hand), which the plugin cannot tell apart from a constructor that sets state.
        opts.unsafeAllow = t.immutables ? "constructor,state-variable-immutable" : "constructor";
        Upgrades.validateUpgrade(t.artifact, opts);
        console2.log("upgrade validated:", t.artifact);
    }

    function _target(string memory name, string memory json) internal view returns (Target memory t) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("hub")) t = Target("AethraHub.sol:AethraHub", vm.parseJsonAddress(json, ".hub"), false, false);
        else if (h == keccak256("hook")) t = Target("AethraHook.sol:AethraHook", vm.parseJsonAddress(json, ".hook"), false, true);
        else if (h == keccak256("router")) t = Target("AethraRouter.sol:AethraRouter", vm.parseJsonAddress(json, ".router"), false, true);
        else if (h == keccak256("positions")) t = Target("AethraPositions.sol:AethraPositions", vm.parseJsonAddress(json, ".positions"), false, true);
        else if (h == keccak256("dlmmFactory")) t = Target("DLMMFactory.sol:DLMMFactory", vm.parseJsonAddress(json, ".dlmmFactory"), false, false);
        else if (h == keccak256("dlmmLimitOrders")) t = Target("DLMMLimitOrders.sol:DLMMLimitOrders", vm.parseJsonAddress(json, ".dlmmLimitOrders"), false, false);
        else if (h == keccak256("dammFactory")) t = Target("DAMMFactory.sol:DAMMFactory", vm.parseJsonAddress(json, ".dammFactory"), false, false);
        else if (h == keccak256("dlmmPool")) t = Target("DLMMPool.sol:DLMMPool", DLMMFactory(vm.parseJsonAddress(json, ".dlmmFactory")).beacon(), true, false);
        else if (h == keccak256("dammPool")) t = Target("DAMMPool.sol:DAMMPool", DAMMFactory(vm.parseJsonAddress(json, ".dammFactory")).beacon(), true, true);
        else if (h == keccak256("launchpad")) t = Target("AethraLaunchpad.sol:AethraLaunchpad", _hidden(json, "launchpad"), false, false);
        else if (h == keccak256("buyback")) t = Target("AethraBuyback.sol:AethraBuyback", _hidden(json, "buyback"), false, false);
        else if (h == keccak256("lendingVault")) t = Target("LendingVault.sol:LendingVault", _hidden(json, "lendingVault"), false, false);
        else if (h == keccak256("creditManager")) t = Target("CreditManager.sol:CreditManager", _hidden(json, "creditManager"), false, false);
        else revert("Upgrade: unknown CONTRACT");
    }

    /// @dev Modules that are built but not shown: the address is top-level once visible, otherwise under `hidden`.
    function _hidden(string memory json, string memory key) internal view returns (address a) {
        a = _addressOrZero(json, string.concat(".", key));
        if (a == address(0)) a = _addressOrZero(json, string.concat(".hidden.", key));
    }

    /// @dev A JSON `null` (module not deployed on this network) reads as the zero address.
    function _addressOrZero(string memory json, string memory key) internal view returns (address) {
        bytes memory raw = vm.parseJson(json, key);
        return raw.length == 32 ? abi.decode(raw, (address)) : address(0);
    }

    function _deployImplementation(string memory name, string memory json) internal returns (address) {
        bytes32 h = keccak256(bytes(name));
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        if (h == keccak256("hub")) return address(new AethraHub());
        if (h == keccak256("hook")) return address(new AethraHook(pm));
        if (h == keccak256("router")) return address(new AethraRouter(pm, vm.parseJsonAddress(json, ".weth")));
        if (h == keccak256("positions")) return address(new AethraPositions(pm));
        if (h == keccak256("dlmmFactory")) return address(new DLMMFactory());
        if (h == keccak256("dlmmLimitOrders")) return address(new DLMMLimitOrders());
        if (h == keccak256("dammFactory")) return address(new DAMMFactory());
        if (h == keccak256("dlmmPool")) return address(new DLMMPool());
        if (h == keccak256("dammPool")) return address(new DAMMPool(IAethraHub(vm.parseJsonAddress(json, ".hub"))));
        if (h == keccak256("launchpad")) return address(new AethraLaunchpad());
        if (h == keccak256("buyback")) return address(new AethraBuyback());
        if (h == keccak256("lendingVault")) return address(new LendingVault());
        if (h == keccak256("creditManager")) return address(new CreditManager());
        revert("Upgrade: unknown CONTRACT");
    }

    /// @dev "Name.sol:Name" -> "Name"
    function _contractOf(string memory artifact) internal pure returns (string memory) {
        bytes memory b = bytes(artifact);
        uint256 i = b.length;
        while (i > 0 && b[i - 1] != ":") i--;
        bytes memory out = new bytes(b.length - i);
        for (uint256 j; j < out.length; j++) out[j] = b[i + j];
        return string(out);
    }
}
