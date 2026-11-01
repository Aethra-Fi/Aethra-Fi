// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {AethraHook} from "../../src/hooks/AethraHook.sol";
import {DLMMFactory} from "../../src/dlmm/DLMMFactory.sol";
import {DLMMPool} from "../../src/dlmm/DLMMPool.sol";
import {AethraLaunchpad} from "../../src/launchpad/AethraLaunchpad.sol";

/// @notice Release v1.3 on mainnet: launchpad markets, and protocol fees to the treasury.
///
/// `MODE=open` (one batch from the deployer, which owns every contract):
///   1. Upgrades the v4 hook (UUPS) and the DLMM pool beacon to implementations whose `collectProtocolFees` falls
///      back to `hub.treasury()` while no buyback is set (DAMM pools and the launchpad already did).
///   2. `hub.setFeeConfig(0, treasury, PROTOCOL_SHARE_BPS)`: a share of every swap fee accrues to the protocol and is
///      swept to the treasury. The buyback stays unset until v1.4.
///   3. `hub.setRegistrar(launchpad, true)`: `create` works (it registers the curve market in the hub).
/// `MODE=lock`: closes the launchpad and sets the protocol share back to 0. The upgrades stay (they only add the
/// treasury fallback).
///
/// Every step is checked after it runs. Run through scripts/mainnet-v13.sh.
contract ReleaseV13 is Script {
    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// 20% of each swap fee; LPs keep 80%. Same share the release plan gives the buyback in v1.4.
    uint16 internal constant PROTOCOL_SHARE_BPS = 2000;

    function run() external {
        require(block.chainid == 4663 || block.chainid == 31337, "ReleaseV13: not mainnet (or a fork of it)");
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../sdk/src/addresses/mainnet.json"));
        AethraHub hub = AethraHub(vm.parseJsonAddress(json, ".hub"));
        address hookProxy = vm.parseJsonAddress(json, ".hook");
        UpgradeableBeacon beacon = UpgradeableBeacon(DLMMFactory(vm.parseJsonAddress(json, ".dlmmFactory")).beacon());
        AethraLaunchpad launchpad = AethraLaunchpad(_launchpad(json));
        IPoolManager pm = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        bool open = keccak256(bytes(vm.envString("MODE"))) == keccak256("open");

        require(hub.owner() == DEPLOYER && beacon.owner() == DEPLOYER && launchpad.owner() == DEPLOYER, "ReleaseV13: owner is not the deployer");
        address treasury = hub.treasury();
        require(treasury != address(0), "ReleaseV13: hub treasury unset");
        require(hub.buyback() == address(0), "ReleaseV13: buyback is set (v1.4 already open)");

        vm.startBroadcast();
        if (open) {
            address hookImpl = address(new AethraHook(pm));
            UUPSUpgradeable(hookProxy).upgradeToAndCall(hookImpl, "");
            address poolImpl = _verifiable("DLMMPool", type(DLMMPool).creationCode);
            beacon.upgradeTo(poolImpl);
            hub.setFeeConfig(address(0), treasury, PROTOCOL_SHARE_BPS);
            hub.setRegistrar(address(launchpad), true);
            vm.stopBroadcast();

            require(address(uint160(uint256(vm.load(hookProxy, IMPLEMENTATION_SLOT)))) == hookImpl, "ReleaseV13: hook not upgraded");
            require(beacon.implementation() == poolImpl, "ReleaseV13: DLMM beacon not upgraded");
            console2.log("hook implementation      ", hookImpl);
            console2.log("DLMM pool implementation ", poolImpl);
        } else {
            hub.setRegistrar(address(launchpad), false);
            hub.setFeeConfig(address(0), treasury, 0);
            vm.stopBroadcast();
        }

        require(hub.isRegistrar(address(launchpad)) == open, "ReleaseV13: launchpad registrar");
        require(hub.protocolFeeShareBps() == (open ? PROTOCOL_SHARE_BPS : 0), "ReleaseV13: protocol share");
        require(hub.treasury() == treasury && hub.buyback() == address(0), "ReleaseV13: fee config");
        (address gpm, address gpos, address ghook) = launchpad.graduationTargets();
        require(gpm == address(pm) && gpos == vm.parseJsonAddress(json, ".positions") && ghook == hookProxy, "ReleaseV13: graduation targets");
        console2.log(open ? "v1.3 open" : "v1.3 locked");
        console2.log("treasury                 ", treasury);
        console2.log("protocol share (bps)     ", hub.protocolFeeShareBps());
        console2.log("graduation threshold (wei)", launchpad.graduationThreshold());
    }

    function _launchpad(string memory json) internal view returns (address a) {
        bytes memory raw = vm.parseJson(json, ".launchpad");
        if (raw.length == 32) a = abi.decode(raw, (address));
        if (a == address(0)) a = vm.parseJsonAddress(json, ".hidden.launchpad");
    }

    /// @dev Same as Deploy.s.sol: deploys verifiable/<name>.bin (scripts/build-verifiable.mjs) so the explorer can
    ///      verify it.
    function _verifiable(string memory name, bytes memory fallbackCode) internal returns (address a) {
        string memory path = string.concat(vm.projectRoot(), "/verifiable/", name, ".bin");
        bytes memory code;
        if (vm.exists(path)) code = vm.parseBytes(vm.trim(vm.readFile(path)));
        else if (block.chainid == 31337) code = fallbackCode;
        else revert(string.concat("ReleaseV13: missing verifiable/", name, ".bin, run node scripts/build-verifiable.mjs"));
        assembly {
            a := create(0, add(code, 0x20), mload(code))
        }
        require(a != address(0), "ReleaseV13: verifiable create failed");
    }
}
