// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMorpho, MarketParams, IOracle} from "./IMorpho.sol";

contract MorphoLiquidator is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant LIQUIDATOR = keccak256("LIQUIDATOR");

    IMorpho public immutable MORPHO;

    constructor(address _morpho) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        MORPHO = IMorpho(_morpho);
    }

    /// @notice Liquidate an undercollateralized position
    /// @notice The liquidator must approve the debt token amount to the liquidator contract beforehand
    /// @param _marketParams The market parameters identifying the Morpho market
    /// @param _borrower The address of the borrower to liquidate
    /// @param _debtToRepay The amount of debt to repay
    /// @param _minCollateralOut Minimum collateral to receive (slippage protection)
    /// @return seizedCollateral The amount of collateral seized
    function liquidate(
        MarketParams memory _marketParams,
        address _borrower,
        uint256 _debtToRepay,
        uint256 _minCollateralOut
    ) external onlyRole(LIQUIDATOR) returns (uint256 seizedCollateral) {
        MORPHO.accrueInterest(_marketParams);

        (
            ,
            ,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares
        ) = _positionData(_marketParams, _borrower);

        uint256 sharesToRepay = (_debtToRepay * uint256(totalBorrowShares)) /
            uint256(totalBorrowAssets);

        IERC20(_marketParams.loanToken).safeTransferFrom(
            msg.sender,
            address(this),
            _debtToRepay
        );

        IERC20(_marketParams.loanToken).forceApprove(
            address(MORPHO),
            _debtToRepay
        );

        (seizedCollateral, ) = MORPHO.liquidate(
            _marketParams,
            _borrower,
            0,
            sharesToRepay,
            ""
        );

        require(seizedCollateral >= _minCollateralOut, "Slippage exceeded");

        IERC20(_marketParams.collateralToken).safeTransfer(
            msg.sender,
            seizedCollateral
        );
    }

    /// @notice Calculate the maximum debt that can be repaid for a liquidation
    /// @param _marketParams The market parameters
    /// @param _borrower The borrower address
    /// @param _liquidationPenalty The liquidation penalty (e.g., 0.0261e18 for 2.61%)
    /// @return debtAssetsToLiquidate The maximum debt in assets that can be liquidated
    function maxDebtToRepay(
        MarketParams memory _marketParams,
        address _borrower,
        uint256 _liquidationPenalty
    ) external view returns (uint256 debtAssetsToLiquidate) {
        (
            uint128 borrowerDebtShares,
            uint128 borrowerCollateral,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares
        ) = _positionData(_marketParams, _borrower);

        uint256 lif = 1e18 + _liquidationPenalty;

        // Max debt based on collateral value
        uint256 maxDebtAssets = (uint256(borrowerCollateral) *
            IOracle(_marketParams.oracle).price() *
            1e18) / (lif * 1e36);

        // Cap at borrower's actual debt (converted to assets)
        uint256 borrowerDebtAssets = (uint256(borrowerDebtShares) *
            uint256(totalBorrowAssets)) / uint256(totalBorrowShares);

        if (maxDebtAssets > borrowerDebtAssets)
            maxDebtAssets = borrowerDebtAssets;

        debtAssetsToLiquidate = (maxDebtAssets * 999) / 1000;
    }

    function _positionData(
        MarketParams memory _marketParams,
        address _borrower
    )
        internal
        view
        returns (
            uint128 borrowerDebtShares,
            uint128 borrowerCollateral,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares
        )
    {
        bytes32 marketId = _marketId(_marketParams);

        (, borrowerDebtShares, borrowerCollateral) = MORPHO.position(
            marketId,
            _borrower
        );
        (, , totalBorrowAssets, totalBorrowShares, , ) = MORPHO.market(
            marketId
        );
    }

    function _marketId(
        MarketParams memory _marketParams
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _marketParams.loanToken,
                    _marketParams.collateralToken,
                    _marketParams.oracle,
                    _marketParams.irm,
                    _marketParams.lltv
                )
            );
    }

    function recover(address _token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(_token).safeTransfer(
            msg.sender,
            IERC20(_token).balanceOf(address(this))
        );
    }
}
