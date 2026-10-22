// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IAethraBuyback, IAethraRouter} from "../interfaces/IAethraPeriphery.sol";
import {IAethraHub} from "../interfaces/IAethraHub.sol";

/// @title AethraBuyback
/// @notice Protocol revenue sink. Pools, the v4 hook and the launchpad send fee tokens here; a keeper periodically
///         sends a treasury share to the hub treasury, swaps the rest into AETH through the Aethra router and burns it.
///         Native ETH revenue is tracked as token address(0) and enters the router wrapped (route starts at WETH).
///         UUPS proxy, ERC-7201 storage.
contract AethraBuyback is IAethraBuyback, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    /// @custom:storage-location erc7201:aethra.storage.Buyback
    struct BuybackStorage {
        IAethraHub hub;
        IAethraRouter router;
        address aeth;
        uint64 cooldown;
        uint16 treasuryBps;
        uint256 totalBurned;
        mapping(address => uint256) totalBought; // tokenIn spent on AETH (treasury share excluded)
        mapping(address => uint64) lastExecution;
        mapping(address => uint256) syncedBalance;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.Buyback")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BUYBACK_STORAGE = 0x6279080838d276cfeae807936e9bb36f72814dd95e63f342932aa4da7c62d700;

    event ConfigSet(address router, uint64 cooldown, uint16 treasuryBps);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error InvalidParams();
    error BadRoute();
    error ZeroAmount();
    error InsufficientBalance();
    error TransferFailed();

    function _s() private pure returns (BuybackStorage storage $) {
        assembly {
            $.slot := BUYBACK_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, IAethraHub hub_, IAethraRouter router_, address aeth_) external initializer {
        if (aeth_ == address(0)) revert InvalidParams();
        __Ownable_init(owner_);
        BuybackStorage storage $ = _s();
        ($.hub, $.aeth) = (hub_, aeth_);
        _setConfig(router_, 1 hours, 2000);
    }

    receive() external payable {}

    // ------------------------------------------------------------------ revenue

    /// @notice Emit RevenueReceived for the balance increase of `token` since the last sync (token 0 = native ETH).
    function sync(address token) external returns (uint256 received) {
        return _sync(token);
    }

    function _sync(address token) internal returns (uint256 received) {
        BuybackStorage storage $ = _s();
        uint256 bal = _balance(token);
        uint256 last = $.syncedBalance[token];
        if (bal > last) {
            received = bal - last;
            emit RevenueReceived(token, received, msg.sender);
        }
        $.syncedBalance[token] = bal;
    }

    /// @notice Treasury share of `amountIn` to the hub treasury, the rest swapped to AETH along `route` and burned.
    ///         With tokenIn == AETH the rest is burned directly and `route` is ignored.
    function execute(address tokenIn, uint256 amountIn, IAethraRouter.Hop[] calldata route, uint256 minAethOut)
        external
        nonReentrant
        returns (uint256 burned)
    {
        BuybackStorage storage $ = _s();
        if (msg.sender != owner() && !$.hub.isOperator(msg.sender)) revert NotKeeper();
        uint256 last = $.lastExecution[tokenIn];
        if (last != 0 && block.timestamp < last + $.cooldown) revert Cooldown();
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > _balance(tokenIn)) revert InsufficientBalance();
        $.lastExecution[tokenIn] = uint64(block.timestamp);

        address aeth_ = $.aeth;
        _sync(tokenIn);
        if (tokenIn != aeth_) _sync(aeth_);
        address treasury = $.hub.treasury();
        uint256 toTreasury = treasury == address(0) ? 0 : amountIn * $.treasuryBps / BPS;
        uint256 spend = amountIn - toTreasury;
        uint256 bought;

        if (tokenIn == aeth_) {
            burned = spend;
        } else {
            IAethraRouter r = $.router;
            uint256 n = route.length;
            address first = tokenIn == address(0) ? r.weth() : tokenIn;
            if (n == 0 || route[0].tokenIn != first || route[n - 1].tokenOut != aeth_) revert BadRoute();
            if (spend != 0) {
                uint256 before = IERC20(aeth_).balanceOf(address(this));
                uint256 value;
                if (tokenIn == address(0)) value = spend;
                else IERC20(tokenIn).forceApprove(address(r), spend);
                r.swap{value: value}(route, spend, minAethOut, address(this), block.timestamp, false);
                bought = IERC20(aeth_).balanceOf(address(this)) - before;
            }
            burned = bought;
        }
        if (burned < minAethOut) revert Slippage();

        $.totalBought[tokenIn] += spend;
        $.totalBurned += burned;
        if (toTreasury != 0) _send(tokenIn, treasury, toTreasury);
        if (burned != 0) ERC20Burnable(aeth_).burn(burned);
        $.syncedBalance[tokenIn] = _balance(tokenIn);
        if (tokenIn != aeth_) $.syncedBalance[aeth_] = _balance(aeth_);
        emit BuybackExecuted(tokenIn, amountIn, bought, burned, toTreasury);
    }

    // ------------------------------------------------------------------ views

    function totalBurned() external view returns (uint256) {
        return _s().totalBurned;
    }

    function totalBought(address tokenIn) external view returns (uint256 spent) {
        return _s().totalBought[tokenIn];
    }

    function aeth() external view returns (address) {
        return _s().aeth;
    }

    function lastExecution(address tokenIn) external view returns (uint64) {
        return _s().lastExecution[tokenIn];
    }

    /// @notice Earliest timestamp `execute(tokenIn, ...)` is allowed again.
    function nextExecution(address tokenIn) external view returns (uint256) {
        uint256 last = _s().lastExecution[tokenIn];
        return last == 0 ? 0 : last + _s().cooldown;
    }

    function config() external view returns (IAethraHub hub, IAethraRouter router, uint64 cooldown, uint16 treasuryBps) {
        BuybackStorage storage $ = _s();
        return ($.hub, $.router, $.cooldown, $.treasuryBps);
    }

    // ------------------------------------------------------------------ admin

    function setConfig(IAethraRouter router_, uint64 cooldown_, uint16 treasuryBps_) external onlyOwner {
        _setConfig(router_, cooldown_, treasuryBps_);
    }

    function rescue(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        _send(token, to, amount);
        _s().syncedBalance[token] = _balance(token);
        emit Rescued(token, to, amount);
    }

    function _setConfig(IAethraRouter router_, uint64 cooldown_, uint16 treasuryBps_) internal {
        if (treasuryBps_ > BPS) revert InvalidParams();
        BuybackStorage storage $ = _s();
        ($.router, $.cooldown, $.treasuryBps) = (router_, cooldown_, treasuryBps_);
        emit ConfigSet(address(router_), cooldown_, treasuryBps_);
    }

    function _balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
