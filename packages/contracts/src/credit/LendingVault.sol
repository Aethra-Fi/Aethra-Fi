// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILendingVault} from "../interfaces/IAethraPeriphery.sol";
import {IAethraHub} from "../interfaces/IAethraHub.sol";

/// @title LendingVault
/// @notice ERC-4626 vault over a USD stablecoin. Suppliers earn the interest paid by CreditManager borrowers.
///         Debt is tracked as debt shares that grow with a RAY borrow index; a kinked utilization curve sets the rate.
///         totalAssets = cash + borrows - protocol reserves. UUPS proxy, ERC-7201 storage.
contract LendingVault is ILendingVault, ERC4626Upgradeable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MAX_RATE_PER_YEAR = 50e18; // 5000% APR hard ceiling for the curve
    uint16 internal constant MAX_RESERVE_FACTOR_BPS = 5000;
    /// @dev Virtual-share offset against the first-depositor inflation attack.
    uint8 internal constant DECIMALS_OFFSET = 6;

    /// @custom:storage-location erc7201:aethra.storage.LendingVault
    struct VaultStorage {
        IAethraHub hub;
        address creditManager;
        uint256 totalDebtShares;
        uint256 borrowIndex; // RAY
        uint256 protocolReserves;
        uint64 lastAccrual;
        uint16 reserveFactorBps;
        uint16 kinkBps;
        uint256 baseRatePerYear; // WAD
        uint256 slope1; // WAD per year, added linearly up to the kink
        uint256 slope2; // WAD per year, added linearly from the kink to 100%
        uint256 supplyCap; // max totalAssets
        uint256 borrowCap; // max totalBorrows
    }

    // keccak256(abi.encode(uint256(keccak256("aethra.storage.LendingVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_STORAGE = 0xc8b38951d442ecd2e5e75d0d1e14e6fc909337469b39e510e8ca389527cef300;

    event CreditManagerSet(address indexed creditManager);
    event RateModelSet(uint256 baseRatePerYear, uint256 slope1, uint256 slope2, uint16 kinkBps);
    event ReserveFactorSet(uint16 reserveFactorBps);
    event CapsSet(uint256 supplyCap, uint256 borrowCap);
    event ReservesWithdrawn(address indexed to, uint256 amount);

    error NotCreditManager();
    error InvalidParams();
    error BorrowCapExceeded();
    error InsufficientCash();
    error ZeroAmount();

    function _s() private pure returns (VaultStorage storage $) {
        assembly {
            $.slot := VAULT_STORAGE
        }
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 asset_, IAethraHub hub_, address owner_, string calldata name_, string calldata symbol_)
        external
        initializer
    {
        __ERC20_init(name_, symbol_);
        __ERC4626_init(asset_);
        __Ownable_init(owner_);
        VaultStorage storage $ = _s();
        $.hub = hub_;
        $.borrowIndex = RAY;
        $.lastAccrual = uint64(block.timestamp);
        $.supplyCap = type(uint256).max;
        $.borrowCap = type(uint256).max;
        _setRateModel(0, 0.04e18, 3e18, 8000); // 0% base, 4% at the 80% kink, 304% at 100%
        _setReserveFactor(1000);
    }

    modifier onlyCreditManager() {
        if (msg.sender != _s().creditManager) revert NotCreditManager();
        _;
    }

    // ------------------------------------------------------------------ borrowing (credit manager only)

    function lend(uint256 assets, address to) external onlyCreditManager nonReentrant returns (uint256 debtShares) {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        VaultStorage storage $ = _s();
        uint256 index = $.borrowIndex;
        if (_borrows($.totalDebtShares, index) + assets > $.borrowCap) revert BorrowCapExceeded();
        if (assets > _availableCash()) revert InsufficientCash();
        debtShares = assets.mulDiv(RAY, index, Math.Rounding.Ceil);
        $.totalDebtShares += debtShares;
        IERC20(asset()).safeTransfer(to, assets);
        emit Borrowed(to, assets, debtShares);
    }

    function repayDebt(uint256 assets, address from)
        external
        onlyCreditManager
        nonReentrant
        returns (uint256 debtSharesBurned)
    {
        if (assets == 0) revert ZeroAmount();
        _accrue();
        VaultStorage storage $ = _s();
        debtSharesBurned = Math.min(assets.mulDiv(RAY, $.borrowIndex), $.totalDebtShares);
        $.totalDebtShares -= debtSharesBurned;
        IERC20(asset()).safeTransferFrom(from, address(this), assets);
        emit Repaid(from, assets, debtSharesBurned);
    }

    function accrueInterest() external {
        _accrue();
    }

    // ------------------------------------------------------------------ ERC-4626 overrides

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrue();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrue();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrue();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrue();
        return super.redeem(shares, receiver, owner_);
    }

    /// @notice cash + borrows (with pending interest) - protocol reserves.
    function totalAssets() public view override returns (uint256) {
        (uint256 index, uint256 reserves) = _pending();
        uint256 gross = _cash() + _borrows(_s().totalDebtShares, index);
        return gross > reserves ? gross - reserves : 0;
    }

    function maxDeposit(address) public view override returns (uint256) {
        uint256 cap = _s().supplyCap;
        if (cap == type(uint256).max) return cap;
        uint256 ta = totalAssets();
        return cap > ta ? cap - ta : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == type(uint256).max ? assets : _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice Limited by the owner's balance and the cash not lent out (reserves are not withdrawable by LPs).
    function maxWithdraw(address owner_) public view override returns (uint256) {
        (, uint256 reserves) = _pending();
        return Math.min(_convertToAssets(balanceOf(owner_), Math.Rounding.Floor), _availableCash(reserves));
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        (, uint256 reserves) = _pending();
        return Math.min(balanceOf(owner_), _convertToShares(_availableCash(reserves), Math.Rounding.Floor));
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    // ------------------------------------------------------------------ views

    function debtSharesToAssets(uint256 debtShares) public view returns (uint256) {
        (uint256 index,) = _pending();
        return debtShares.mulDiv(index, RAY, Math.Rounding.Ceil);
    }

    function assetsToDebtShares(uint256 assets) external view returns (uint256) {
        (uint256 index,) = _pending();
        return assets.mulDiv(RAY, index);
    }

    function totalBorrows() public view returns (uint256) {
        (uint256 index,) = _pending();
        return _borrows(_s().totalDebtShares, index);
    }

    function utilizationBps() external view returns (uint256) {
        (uint256 index, uint256 reserves) = _pending();
        return _utilizationWad(_cash(), _borrows(_s().totalDebtShares, index), reserves) * BPS / WAD;
    }

    function borrowRatePerSecondWad() public view returns (uint256) {
        (uint256 index, uint256 reserves) = _pending();
        return _ratePerSecond(_utilizationWad(_cash(), _borrows(_s().totalDebtShares, index), reserves));
    }

    /// @notice borrowRate * utilization * (1 - reserveFactor).
    function supplyRatePerSecondWad() external view returns (uint256) {
        VaultStorage storage $ = _s();
        (uint256 index, uint256 reserves) = _pending();
        uint256 u = _utilizationWad(_cash(), _borrows($.totalDebtShares, index), reserves);
        return _ratePerSecond(u) * u / WAD * (BPS - $.reserveFactorBps) / BPS;
    }

    function borrowIndexRay() external view returns (uint256 index) {
        (index,) = _pending();
    }

    function protocolReserves() external view returns (uint256 reserves) {
        (, reserves) = _pending();
    }

    function totalDebtShares() external view returns (uint256) {
        return _s().totalDebtShares;
    }

    /// @notice Cash LPs can withdraw / the credit manager can borrow right now.
    function availableCash() external view returns (uint256) {
        (, uint256 reserves) = _pending();
        return _availableCash(reserves);
    }

    function hub() external view returns (IAethraHub) {
        return _s().hub;
    }

    function creditManager() external view returns (address) {
        return _s().creditManager;
    }

    function rateModel()
        external
        view
        returns (uint256 baseRatePerYear, uint256 slope1, uint256 slope2, uint16 kinkBps, uint16 reserveFactorBps)
    {
        VaultStorage storage $ = _s();
        return ($.baseRatePerYear, $.slope1, $.slope2, $.kinkBps, $.reserveFactorBps);
    }

    function caps() external view returns (uint256 supplyCap, uint256 borrowCap) {
        return (_s().supplyCap, _s().borrowCap);
    }

    // ------------------------------------------------------------------ admin

    function setCreditManager(address cm) external onlyOwner {
        _s().creditManager = cm;
        emit CreditManagerSet(cm);
    }

    function setRateModel(uint256 baseRatePerYear, uint256 slope1, uint256 slope2, uint16 kinkBps) external onlyOwner {
        _accrue();
        _setRateModel(baseRatePerYear, slope1, slope2, kinkBps);
    }

    function setReserveFactor(uint16 reserveFactorBps) external onlyOwner {
        _accrue();
        _setReserveFactor(reserveFactorBps);
    }

    function setCaps(uint256 supplyCap, uint256 borrowCap) external onlyOwner {
        (_s().supplyCap, _s().borrowCap) = (supplyCap, borrowCap);
        emit CapsSet(supplyCap, borrowCap);
    }

    /// @notice Send accrued protocol reserves (up to the idle cash) to the hub treasury.
    function withdrawReserves(uint256 amount) external onlyOwner nonReentrant {
        _accrue();
        VaultStorage storage $ = _s();
        amount = Math.min(Math.min(amount, $.protocolReserves), _cash());
        if (amount == 0) revert ZeroAmount();
        $.protocolReserves -= amount;
        address to = $.hub.treasury();
        IERC20(asset()).safeTransfer(to, amount);
        emit ReservesWithdrawn(to, amount);
    }

    function _setRateModel(uint256 base, uint256 s1, uint256 s2, uint16 kink) internal {
        if (kink == 0 || kink >= BPS || base + s1 + s2 > MAX_RATE_PER_YEAR) revert InvalidParams();
        VaultStorage storage $ = _s();
        ($.baseRatePerYear, $.slope1, $.slope2, $.kinkBps) = (base, s1, s2, kink);
        emit RateModelSet(base, s1, s2, kink);
    }

    function _setReserveFactor(uint16 rf) internal {
        if (rf > MAX_RESERVE_FACTOR_BPS) revert InvalidParams();
        _s().reserveFactorBps = rf;
        emit ReserveFactorSet(rf);
    }

    // ------------------------------------------------------------------ internals

    function _accrue() internal {
        VaultStorage storage $ = _s();
        if ($.lastAccrual == block.timestamp) return;
        uint256 oldIndex = $.borrowIndex;
        (uint256 index, uint256 reserves) = _pending();
        $.lastAccrual = uint64(block.timestamp);
        if (index == oldIndex) return;
        uint256 interest = _borrows($.totalDebtShares, index) - _borrows($.totalDebtShares, oldIndex);
        ($.borrowIndex, $.protocolReserves) = (index, reserves);
        emit InterestAccrued(interest, reserves, index);
    }

    /// @dev Borrow index and reserves as they would be after accruing to the current block.
    function _pending() internal view returns (uint256 index, uint256 reserves) {
        VaultStorage storage $ = _s();
        index = $.borrowIndex;
        reserves = $.protocolReserves;
        uint256 dt = block.timestamp - $.lastAccrual;
        uint256 shares = $.totalDebtShares;
        if (dt == 0 || shares == 0) return (index, reserves);
        uint256 borrows = _borrows(shares, index);
        uint256 rate = _ratePerSecond(_utilizationWad(_cash(), borrows, reserves));
        index += index.mulDiv(rate * dt, WAD);
        uint256 interest = _borrows(shares, index) - borrows;
        reserves += interest * $.reserveFactorBps / BPS;
    }

    function _borrows(uint256 shares, uint256 index) internal pure returns (uint256) {
        return shares.mulDiv(index, RAY, Math.Rounding.Ceil);
    }

    function _cash() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function _availableCash() internal view returns (uint256) {
        return _availableCash(_s().protocolReserves);
    }

    function _availableCash(uint256 reserves) internal view returns (uint256) {
        uint256 cash = _cash();
        return cash > reserves ? cash - reserves : 0;
    }

    function _utilizationWad(uint256 cash, uint256 borrows, uint256 reserves) internal pure returns (uint256) {
        if (borrows == 0) return 0;
        uint256 supplied = cash + borrows;
        supplied = supplied > reserves ? supplied - reserves : 0;
        if (supplied <= borrows) return WAD;
        return borrows.mulDiv(WAD, supplied);
    }

    function _ratePerSecond(uint256 u) internal view returns (uint256) {
        VaultStorage storage $ = _s();
        uint256 kink = uint256($.kinkBps) * WAD / BPS;
        uint256 perYear = $.baseRatePerYear;
        if (u <= kink) {
            perYear += $.slope1 * u / kink;
        } else {
            perYear += $.slope1 + $.slope2 * (u - kink) / (WAD - kink);
        }
        return perYear / YEAR;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
