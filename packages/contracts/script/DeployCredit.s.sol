// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAethraHub} from "../src/interfaces/IAethraHub.sol";
import {ILendingVault, IAethraPositions, IAethraRouter} from "../src/interfaces/IAethraPeriphery.sol";
import {LendingVault} from "../src/credit/LendingVault.sol";
import {CreditManager} from "../src/credit/CreditManager.sol";

/// @notice Deploys the lending vault and credit manager on top of a deployed core (run after Deploy and,
///         on local/testnet, after SetupMarkets so the default aUSD vault asset exists).
/// @dev VAULT_ASSET overrides the stablecoin (required on mainnet). Mainnet is dry-run only.
contract DeployCredit is Script {
    address internal constant DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;

    function run() external returns (address vault, address cm) {
        string memory network = vm.envOr("NETWORK", string("local"));
        string memory path = string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json");
        string memory json = vm.readFile(path);
        require(msg.sender == DEPLOYER, "DeployCredit: sender must be the Aethra deployer");

        address hub = vm.parseJsonAddress(json, ".hub");
        address positions = vm.parseJsonAddress(json, ".positions");
        address router = vm.parseJsonAddress(json, ".router");
        address asset = vm.envOr("VAULT_ASSET", address(0));
        if (asset == address(0)) asset = vm.parseJsonAddress(json, ".tokens.aUSD.address");
        require(asset.code.length > 0, "DeployCredit: vault asset missing");

        vm.startBroadcast();
        vault = address(
            new ERC1967Proxy(
                address(new LendingVault()),
                abi.encodeCall(LendingVault.initialize, (IERC20(asset), IAethraHub(hub), DEPLOYER, "Aethra USD Vault", "aeUSD"))
            )
        );
        cm = address(
            new ERC1967Proxy(
                address(new CreditManager()),
                abi.encodeCall(
                    CreditManager.initialize,
                    (DEPLOYER, IAethraHub(hub), IAethraPositions(positions), ILendingVault(vault), IAethraRouter(router))
                )
            )
        );
        LendingVault(vault).setCreditManager(cm);
        vm.stopBroadcast();

        console2.log("lendingVault ", vault);
        console2.log("creditManager", cm);
        if (keccak256(bytes(network)) != keccak256("mainnet") && vm.envOr("WRITE_ADDRESSES", true)) {
            vm.writeJson(string.concat('"', vm.toString(vault), '"'), path, ".lendingVault");
            vm.writeJson(string.concat('"', vm.toString(cm), '"'), path, ".creditManager");
        }
    }
}
