// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ICreditManager, ILendingVault, IAethraPositions, IAethraRouter} from "../interfaces/IAethraPeriphery.sol";
import {IAethraHub} from "../interfaces/IAethraHub.sol";

/// @title CreditManager
/// @notice Borrow the LendingVault's stablecoin against pledged Aethra position NFTs. Collateral is valued from the
///         position's token amounts at hub oracle prices; the stablecoin is treated as 1 USD. While pledged, LP fees
///         keep flowing to the loan owner through `harvest`, or can pay down the debt via `autoRepayFromFees`.
///         UUPS proxy, ERC-7201 storage.
contract CreditManager is ICreditManager, IERC721Receiver, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    using Math for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @custom:storage-location erc7201:aethra.storage.CreditManager
    struct CreditStorage {
        IAethraHub hub;
        IAethraPositions positions;
        ILendingVault vault;
        IAethraRouter router;
        address asset;
        uint8 assetDecimals;
        uint16 maxLtvBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint256 minDebt; // in asset units
        mapping(uint256 => Loan) loans;
        mapping(address => EnumerableSet.UintSet) ownerLoans;
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.CreditManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CREDIT_STORAGE = 0x5605a14371f114c9bed264c681224f435d2e4b609b7f8ac565d3b022ef66b300;

    event RiskParamsSet(uint16 maxLtvBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps, uint256 minDebt);
    event RouterSet(address indexed router);
    event FeesHarvested(uint256 indexed tokenId, address indexed to, uint256 fee0, uint256 fee1);
    event AutoRepaid(uint256 indexed tokenId, uint256 assetsFromFees, uint256 repaid, uint256 refunded);

    error InvalidParams();
    error UnknownLoan();
    error BelowMinDebt();
    error UnexpectedNft();
    error NotAuthorized();
    error BadRoute();
    error Slippage();

    function _s() private pure returns (CreditStorage storage $) {
        assembly {
            $.slot := CREDIT_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        IAethraHub hub_,
        IAethraPositions positions_,
        ILendingVault vault_,
        IAethraRouter router_
    ) external initializer {
        __Ownable_init(owner_);
        CreditStorage storage $ = _s();
        ($.hub, $.positions, $.vault, $.router) = (hub_, positions_, vault_, router_);
        address asset_ = IERC4626(address(vault_)).asset();
        uint8 dec = IERC20Metadata(asset_).decimals();
        if (dec > 18) revert InvalidParams();
        ($.asset, $.assetDecimals) = (asset_, dec);
        _setRiskParams(5000, 7000, 500, 0);
    }

    modifier onlyLoanOwner(uint256 tokenId) {
        if (_s().loans[tokenId].owner != msg.sender) revert NotLoanOwner();
        _;
    }

    // ------------------------------------------------------------------ collateral

    /// @notice Pledge a position NFT you own. Approve this contract on the positions NFT first.
    function pledge(uint256 tokenId) external nonReentrant {
        CreditStorage storage $ = _s();
        if ($.positions.ownerOf(tokenId) != msg.sender) revert NotLoanOwner();
        _requireSupported(tokenId);
        $.loans[tokenId] = Loan(msg.sender, 0, uint64(block.timestamp));
        $.ownerLoans[msg.sender].add(tokenId);
        emit Pledged(tokenId, msg.sender);
        IERC721(address($.positions)).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice Withdraw a debt-free position.
    function release(uint256 tokenId) external nonReentrant onlyLoanOwner(tokenId) {
        CreditStorage storage $ = _s();
        if ($.loans[tokenId].debtShares != 0) revert OutstandingDebt();
        _close(tokenId, msg.sender);
        emit Released(tokenId, msg.sender);
        IERC721(address($.positions)).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /// @dev Only accepts NFTs this contract pulls itself during `pledge`.
    function onERC721Received(address operator, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(_s().positions) || operator != address(this)) revert UnexpectedNft();
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ debt

    function borrow(uint256 tokenId, uint256 assets, address to) external nonReentrant onlyLoanOwner(tokenId) {
        CreditStorage storage $ = _s();
        $.vault.accrueInterest();
        _requireSupported(tokenId);
        uint256 newDebt = debtOf(tokenId) + assets;
        if (newDebt < $.minDebt) revert BelowMinDebt();
        if (newDebt > _toAsset(_valueUsd(tokenId)) * $.maxLtvBps / BPS) revert Unhealthy();
        uint256 shares = $.vault.lend(assets, to);
        $.loans[tokenId].debtShares += shares;
        emit Borrow(tokenId, msg.sender, assets);
    }

    /// @notice Repay on behalf of any loan; pulls the stablecoin from the caller. Capped at the debt
    ///         (pass type(uint256).max to repay in full).
    function repay(uint256 tokenId, uint256 assets) external nonReentrant returns (uint256 repaid) {
        CreditStorage storage $ = _s();
        if ($.loans[tokenId].owner == address(0)) revert UnknownLoan();
        $.vault.accrueInterest();
        repaid = Math.min(assets, debtOf(tokenId));
        if (repaid == 0) return 0;
        IERC20($.asset).safeTransferFrom(msg.sender, address(this), repaid);
        _repay(tokenId, repaid);
        emit Repay(tokenId, msg.sender, repaid);
    }

    /// @notice Liquidate an unhealthy loan: repay its full debt and receive the position NFT. The liquidator's
    ///         bonus is capped at `liquidationBonusBps` of the debt; any collateral value above that is paid to the
    ///         loan owner in the stablecoin by the liquidator.
    function liquidate(uint256 tokenId) external nonReentrant {
        CreditStorage storage $ = _s();
        address owner_ = $.loans[tokenId].owner;
        if (owner_ == address(0)) revert UnknownLoan();
        $.vault.accrueInterest();
        uint256 debt = debtOf(tokenId);
        uint256 valueUsd = _valueUsd(tokenId);
        uint256 value = _toAsset(valueUsd);
        if (debt == 0 || valueUsd * $.liquidationThresholdBps / BPS >= debt * 10 ** (18 - $.assetDecimals)) {
            revert Healthy();
        }

        uint256 maxPayout = debt + debt * $.liquidationBonusBps / BPS;
        uint256 surplus = value > maxPayout ? value - maxPayout : 0;

        IERC20 asset_ = IERC20($.asset);
        asset_.safeTransferFrom(msg.sender, address(this), debt + surplus);
        _repay(tokenId, debt);
        _close(tokenId, owner_);
        emit Liquidated(tokenId, msg.sender, debt, valueUsd);
        if (surplus != 0) asset_.safeTransfer(owner_, surplus);
        IERC721(address($.positions)).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    // ------------------------------------------------------------------ fees

    /// @notice Send the pledged position's accrued LP fees to the loan owner. Callable by anyone.
    function harvest(uint256 tokenId) external nonReentrant returns (uint256 fee0, uint256 fee1) {
        CreditStorage storage $ = _s();
        address owner_ = $.loans[tokenId].owner;
        if (owner_ == address(0)) revert UnknownLoan();
        (fee0, fee1) = $.positions.collect(tokenId, owner_);
        emit FeesHarvested(tokenId, owner_, fee0, fee1);
    }

    /// @notice Collect the position's fees, swap them to the stablecoin through the router, repay the loan and send
    ///         any excess to the owner. Callable by the loan owner or a hub operator (keeper). An empty route for a
    ///         non-stablecoin fee token sends that fee straight to the owner.
    function autoRepayFromFees(
        uint256 tokenId,
        IAethraRouter.Hop[] calldata route0,
        IAethraRouter.Hop[] calldata route1,
        uint256 minOut
    ) external nonReentrant returns (uint256 repaid) {
        CreditStorage storage $ = _s();
        address owner_ = $.loans[tokenId].owner;
        if (owner_ == address(0)) revert UnknownLoan();
        if (msg.sender != owner_ && !$.hub.isOperator(msg.sender)) revert NotAuthorized();

        IAethraPositions.Position memory p = $.positions.getPosition(tokenId);
        (uint256 fee0, uint256 fee1) = $.positions.collect(tokenId, address(this));
        uint256 out = _toStable(Currency.unwrap(p.key.currency0), fee0, route0, owner_)
            + _toStable(Currency.unwrap(p.key.currency1), fee1, route1, owner_);
        if (out < minOut) revert Slippage();

        $.vault.accrueInterest();
        repaid = Math.min(out, debtOf(tokenId));
        if (repaid != 0) _repay(tokenId, repaid);
        uint256 refund = out - repaid;
        if (refund != 0) IERC20($.asset).safeTransfer(owner_, refund);
        emit AutoRepaid(tokenId, out, repaid, refund);
    }

    /// @dev Native ETH fees from collect.
    receive() external payable {}

    // ------------------------------------------------------------------ views

    function loan(uint256 tokenId) external view returns (Loan memory) {
        return _s().loans[tokenId];
    }

    function debtOf(uint256 tokenId) public view returns (uint256) {
        uint256 shares = _s().loans[tokenId].debtShares;
        return shares == 0 ? 0 : _s().vault.debtSharesToAssets(shares);
    }

    function health(uint256 tokenId) external view returns (uint256 valueUsdE18, uint256 maxBorrow, uint256 healthFactorE18) {
        CreditStorage storage $ = _s();
        valueUsdE18 = _valueUsd(tokenId);
        maxBorrow = _toAsset(valueUsdE18) * $.maxLtvBps / BPS;
        uint256 debt = debtOf(tokenId);
        healthFactorE18 = debt == 0
            ? type(uint256).max
            : (valueUsdE18 * $.liquidationThresholdBps / BPS).mulDiv(WAD, debt * 10 ** (18 - $.assetDecimals));
    }

    /// @notice Collateral value in USD (1e18) at hub oracle prices. Reverts if a price is missing or stale.
    function collateralValueUsd(uint256 tokenId) external view returns (uint256) {
        return _valueUsd(tokenId);
    }

    /// @notice Whether a position could be pledged right now (fresh prices for both tokens and an enabled pool).
    function isSupported(uint256 tokenId) public view returns (bool) {
        CreditStorage storage $ = _s();
        IAethraPositions.Position memory p = $.positions.getPosition(tokenId);
        if (!$.hub.isPoolEnabled(PoolId.unwrap(p.key.toId()))) return false;
        (, bool fresh0,) = $.hub.tryGetPrice(Currency.unwrap(p.key.currency0));
        (, bool fresh1,) = $.hub.tryGetPrice(Currency.unwrap(p.key.currency1));
        return fresh0 && fresh1;
    }

    function loansOf(address owner_) external view returns (uint256[] memory) {
        return _s().ownerLoans[owner_].values();
    }

    function riskParams()
        external
        view
        returns (uint16 maxLtvBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps, uint256 minDebt)
    {
        CreditStorage storage $ = _s();
        return ($.maxLtvBps, $.liquidationThresholdBps, $.liquidationBonusBps, $.minDebt);
    }

    function contracts()
        external
        view
        returns (IAethraHub hub, IAethraPositions positions, ILendingVault vault, IAethraRouter router, address asset)
    {
        CreditStorage storage $ = _s();
        return ($.hub, $.positions, $.vault, $.router, $.asset);
    }

    // ------------------------------------------------------------------ admin

    function setRiskParams(uint16 maxLtvBps, uint16 liquidationThresholdBps, uint16 liquidationBonusBps, uint256 minDebt)
        external
        onlyOwner
    {
        _setRiskParams(maxLtvBps, liquidationThresholdBps, liquidationBonusBps, minDebt);
    }

    function setRouter(IAethraRouter router_) external onlyOwner {
        _s().router = router_;
        emit RouterSet(address(router_));
    }

    function _setRiskParams(uint16 ltv, uint16 lt, uint16 bonus, uint256 minDebt) internal {
        if (ltv == 0 || ltv > lt || lt >= BPS || bonus > 2000) revert InvalidParams();
        CreditStorage storage $ = _s();
        ($.maxLtvBps, $.liquidationThresholdBps, $.liquidationBonusBps, $.minDebt) = (ltv, lt, bonus, minDebt);
        emit RiskParamsSet(ltv, lt, bonus, minDebt);
    }

    // ------------------------------------------------------------------ internals

    function _requireSupported(uint256 tokenId) internal view {
        if (!isSupported(tokenId)) revert UnsupportedCollateral();
    }

    function _valueUsd(uint256 tokenId) internal view returns (uint256) {
        CreditStorage storage $ = _s();
        IAethraPositions.Position memory p = $.positions.getPosition(tokenId);
        (uint256 a0, uint256 a1) = $.positions.positionAmounts(tokenId);
        return _usd(Currency.unwrap(p.key.currency0), a0) + _usd(Currency.unwrap(p.key.currency1), a1);
    }

    function _usd(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        uint8 dec = token == address(0) ? 18 : IERC20Metadata(token).decimals();
        return amount.mulDiv(_s().hub.getPrice(token), 10 ** dec);
    }

    /// @dev USD (1e18) -> stablecoin units, 1 stablecoin = 1 USD.
    function _toAsset(uint256 usdE18) internal view returns (uint256) {
        return usdE18 / 10 ** (18 - _s().assetDecimals);
    }

    /// @dev Repay `assets` (already held by this contract) for a loan.
    function _repay(uint256 tokenId, uint256 assets) internal {
        CreditStorage storage $ = _s();
        Loan storage l = $.loans[tokenId];
        bool full = assets >= debtOf(tokenId);
        IERC20($.asset).forceApprove(address($.vault), assets);
        uint256 burned = $.vault.repayDebt(assets, address(this));
        l.debtShares = full ? 0 : l.debtShares - Math.min(burned, l.debtShares);
    }

    function _close(uint256 tokenId, address owner_) internal {
        CreditStorage storage $ = _s();
        delete $.loans[tokenId];
        $.ownerLoans[owner_].remove(tokenId);
    }

    function _toStable(address token, uint256 amount, IAethraRouter.Hop[] calldata route, address owner_)
        internal
        returns (uint256 out)
    {
        if (amount == 0) return 0;
        CreditStorage storage $ = _s();
        if (token == $.asset) return amount;
        if (route.length == 0) {
            _send(token, owner_, amount);
            return 0;
        }
        IAethraRouter r = $.router;
        address first = token == address(0) ? r.weth() : token;
        if (route[0].tokenIn != first || route[route.length - 1].tokenOut != $.asset) revert BadRoute();
        uint256 value;
        if (token == address(0)) value = amount;
        else IERC20(token).forceApprove(address(r), amount);
        out = r.swap{value: value}(route, amount, 0, address(this), block.timestamp, false);
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NotAuthorized();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
