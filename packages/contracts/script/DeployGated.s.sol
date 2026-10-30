// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AethraHub} from "../src/core/AethraHub.sol";
import {IAethraHub, AssetClass} from "../src/interfaces/IAethraHub.sol";
import {ILendingVault, IAethraPositions, IAethraRouter} from "../src/interfaces/IAethraPeriphery.sol";
import {AethraLaunchpad} from "../src/launchpad/AethraLaunchpad.sol";
import {LaunchToken} from "../src/launchpad/LaunchToken.sol";
import {AethraToken} from "../src/token/AethraToken.sol";
import {AethraBuyback} from "../src/buyback/AethraBuyback.sol";
import {LendingVault} from "../src/credit/LendingVault.sol";
import {CreditManager} from "../src/credit/CreditManager.sol";

/// @notice Gated modules (mainnet runs them through DeployMainnet; DeployGated runs them alone after Deploy): registers the launch assets and deploys the hidden modules locked on-chain.
///         - Assets: WETH and the stablecoin as CANONICAL (no oracle yet). Stock tokens as STOCK with enabled=false,
///           so the hook refuses to initialize any pool with them until stock pools open (AssetNotEnabled).
///         - Launchpad: deployed, not a hub registrar, so `create` reverts at registerPool.
///         - AETH + buyback: AETH minted once to the deployer; the hub keeps a 0 protocol fee share (Deploy sets it).
///         - Credit: vault over the stablecoin with supply and borrow caps at 0 and no credit manager set.
///         Opening a module later is one owner transaction each (docs/RELEASE_PLAN.md, section 1).
/// @dev NETWORK=<net> STABLECOIN=0x... STOCK_TOKENS=0x..,0x.. forge script script/DeployGated.s.sol ...
///      Addresses go to the `hidden` object of the SDK address file, and on mainnet only on a real broadcast.
/// @dev Shared by DeployGated (core already deployed) and DeployMainnet (core and gated modules in one run).
abstract contract GatedModules is Script {
    address internal constant GATED_DEPLOYER = 0xd09D9c87ECfe008B4D6D3cEbeAd25103c16d9a7C;
    address internal constant GATED_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    struct Gated {
        address launchpad;
        address aeth;
        address buyback;
        address lendingVault;
        address creditManager;
    }

    /// @dev Call inside a broadcast.
    function _deployGated(address hub, address positions, address router, address hook, address weth, address stable, address[] memory stocks)
        internal
        returns (Gated memory o)
    {
        require(stable.code.length > 0, "DeployGated: stablecoin missing on this chain");
        for (uint256 i; i < stocks.length; i++) require(stocks[i].code.length > 0, "DeployGated: stock token missing");
        address owner = GATED_DEPLOYER;

        AethraHub h = AethraHub(hub);
        h.setAsset(weth, AssetClass.CANONICAL, true, address(0), 0);
        h.setAsset(stable, AssetClass.CANONICAL, true, address(0), 0);
        for (uint256 i; i < stocks.length; i++) h.setAsset(stocks[i], AssetClass.STOCK, false, address(0), 0);

        o.launchpad = address(
            new ERC1967Proxy(
                address(new AethraLaunchpad()),
                abi.encodeCall(
                    AethraLaunchpad.initialize,
                    (owner, IAethraHub(hub), weth, address(new LaunchToken()), GATED_POOL_MANAGER, positions, hook)
                )
            )
        );
        o.aeth = address(new AethraToken(owner));
        o.buyback = address(
            new ERC1967Proxy(
                address(new AethraBuyback()),
                abi.encodeCall(AethraBuyback.initialize, (owner, IAethraHub(hub), IAethraRouter(router), o.aeth))
            )
        );
        o.lendingVault = address(
            new ERC1967Proxy(
                address(new LendingVault()),
                abi.encodeCall(LendingVault.initialize, (IERC20(stable), IAethraHub(hub), owner, "Aethra USD Vault", "aeUSD"))
            )
        );
        o.creditManager = address(
            new ERC1967Proxy(
                address(new CreditManager()),
                abi.encodeCall(
                    CreditManager.initialize,
                    (owner, IAethraHub(hub), IAethraPositions(positions), ILendingVault(o.lendingVault), IAethraRouter(router))
                )
            )
        );
        LendingVault(o.lendingVault).setCaps(0, 0);
    }

    function _logGated(Gated memory o) internal pure {
        console2.log("launchpad    ", o.launchpad);
        console2.log("aeth         ", o.aeth);
        console2.log("buyback      ", o.buyback);
        console2.log("lendingVault ", o.lendingVault);
        console2.log("creditManager", o.creditManager);
    }

    function _writeGated(string memory path, Gated memory o) internal {
        _putGated(path, ".hidden.launchpad", o.launchpad);
        _putGated(path, ".hidden.aeth", o.aeth);
        _putGated(path, ".hidden.buyback", o.buyback);
        _putGated(path, ".hidden.lendingVault", o.lendingVault);
        _putGated(path, ".hidden.creditManager", o.creditManager);
    }

    function _putGated(string memory path, string memory key, address a) internal {
        vm.writeJson(string.concat('"', vm.toString(a), '"'), path, key);
    }

    function _stocksFromEnv() internal view returns (address[] memory) {
        return vm.envOr("STOCK_TOKENS", ",", new address[](0));
    }
}

contract DeployGated is GatedModules {
    function run() external returns (Gated memory o) {
        string memory network = vm.envOr("NETWORK", string("mainnet"));
        string memory path = string.concat(vm.projectRoot(), "/../sdk/src/addresses/", network, ".json");
        string memory json = vm.readFile(path);
        require(msg.sender == GATED_DEPLOYER, "DeployGated: sender must be the Aethra deployer");
        address hub = vm.parseJsonAddress(json, ".hub");
        require(hub.code.length > 0, "DeployGated: run Deploy first");

        vm.startBroadcast();
        o = _deployGated(
            hub,
            vm.parseJsonAddress(json, ".positions"),
            vm.parseJsonAddress(json, ".router"),
            vm.parseJsonAddress(json, ".hook"),
            vm.parseJsonAddress(json, ".weth"),
            vm.envAddress("STABLECOIN"),
            _stocksFromEnv()
        );
        vm.stopBroadcast();
        _logGated(o);

        bool write = keccak256(bytes(network)) != keccak256("mainnet") || vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        if (write && vm.envOr("WRITE_ADDRESSES", true)) _writeGated(path, o);
    }
}
