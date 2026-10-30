// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AethraHub} from "../../src/core/AethraHub.sol";
import {IAethraHub} from "../../src/interfaces/IAethraHub.sol";
import {IAethraRouter} from "../../src/interfaces/IAethraPeriphery.sol";
import {AethraLaunchpad} from "../../src/launchpad/AethraLaunchpad.sol";
import {LaunchToken} from "../../src/launchpad/LaunchToken.sol";
import {AethraToken} from "../../src/token/AethraToken.sol";
import {AethraBuyback} from "../../src/buyback/AethraBuyback.sol";

/// @notice Deploys the launchpad, AETH and the buyback on top of a deployed core, then wires them into the hub:
///         the launchpad becomes a registrar and the hub routes a 20% protocol fee share to the buyback.
/// @dev Not part of the active deployment (the launchpad and buyback features are hidden). Run it when they ship:
///      NETWORK=local|testnet forge script script/deferred/DeployLaunchpadBuyback.s.sol --sender $DEPLOYER ...
///      Mainnet is dry-run only and never writes addresses.
contract DeployLaunchpadBuyback is Script {
    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function run() external returns (address launchpad, address aeth, address buyback) {
        string memory network = vm.envOr("NETWORK", string("local"));
        string memory path = string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json");
        string memory json = vm.readFile(path);
        require(msg.sender == DEPLOYER, "DeployLaunchpadBuyback: sender must be the Aethra deployer");

        address hub = vm.parseJsonAddress(json, ".hub");
        address router = vm.parseJsonAddress(json, ".router");
        address positions = vm.parseJsonAddress(json, ".positions");
        address hook = vm.parseJsonAddress(json, ".hook");
        address weth = vm.parseJsonAddress(json, ".weth");

        vm.startBroadcast();
        launchpad = address(
            new ERC1967Proxy(
                address(new AethraLaunchpad()),
                abi.encodeCall(
                    AethraLaunchpad.initialize,
                    (DEPLOYER, IAethraHub(hub), weth, address(new LaunchToken()), POOL_MANAGER, positions, hook)
                )
            )
        );
        aeth = address(new AethraToken(DEPLOYER));
        buyback = address(
            new ERC1967Proxy(
                address(new AethraBuyback()),
                abi.encodeCall(AethraBuyback.initialize, (DEPLOYER, IAethraHub(hub), IAethraRouter(router), aeth))
            )
        );
        AethraHub(hub).setRegistrar(launchpad, true);
        AethraHub(hub).setFeeConfig(buyback, DEPLOYER, 2000); // 20% of LP fees to the protocol; treasury = deployer
        vm.stopBroadcast();

        console2.log("launchpad", launchpad);
        console2.log("aeth     ", aeth);
        console2.log("buyback  ", buyback);
        if (keccak256(bytes(network)) != keccak256("mainnet") && vm.envOr("WRITE_ADDRESSES", true)) {
            vm.writeJson(string.concat('"', vm.toString(launchpad), '"'), path, ".launchpad");
            vm.writeJson(string.concat('"', vm.toString(aeth), '"'), path, ".aeth");
            vm.writeJson(string.concat('"', vm.toString(buyback), '"'), path, ".buyback");
        }
    }
}
