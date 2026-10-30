// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "./Deploy.s.sol";
import {GatedModules} from "./DeployGated.s.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Full mainnet release in one script: core + DLMM + DAMM (Deploy) and the gated modules (GatedModules).
///         One run means one keystore prompt and one gas estimate for the whole release.
/// @dev Dry run (nothing sent): bash scripts/mainnet-deploy.sh. Broadcast: bash scripts/mainnet-deploy.sh --broadcast.
///      forge script script/DeployMainnet.s.sol:DeployMainnet --sig "deployAll()" --rpc-url mainnet --sender $DEPLOYER_ADDRESS
contract DeployMainnet is Deploy, GatedModules {
    function deployAll() external returns (Core memory c, Modules memory m, Gated memory g) {
        network = vm.envOr("NETWORK", string("mainnet"));
        addressesPath = string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json");
        require(msg.sender == DEPLOYER, "DeployMainnet: sender must be the Aethra deployer");
        require(POOL_MANAGER.code.length > 0, "DeployMainnet: PoolManager missing on this chain");
        address weth = vm.parseJsonAddress(vm.readFile(addressesPath), ".weth");
        require(weth.code.length > 0, "DeployMainnet: WETH missing on this chain");
        address stable = vm.envOr("STABLECOIN", vm.parseJsonAddress(vm.readFile(addressesPath), ".tokens.USDG.address"));

        vm.startBroadcast();
        c = _deployCore(weth);
        m = _deployModules(c);
        g = _deployGated(c.hub, c.positions, c.router, c.hook, weth, stable, _stocksFromEnv());
        vm.stopBroadcast();

        _log(c, m);
        _logGated(g);
        if (_shouldWrite()) {
            _write(c, m);
            _writeGated(addressesPath, g);
        }
    }
}
