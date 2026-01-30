// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMorpho, MarketParams, IOracle} from "./IMorpho.sol";

contract MorphoLiquidator {
    IMorpho public immutable MORPHO;

    constructor(address _morpho) {
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
    ) external returns (uint256 seizedCollateral) {
        (
            ,
            ,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares
        ) = _positionData(_marketParams, _borrower);

        uint256 sharesToRepay = (_debtToRepay * uint256(totalBorrowShares)) /
            uint256(totalBorrowAssets);

        IERC20(_marketParams.loanToken).transferFrom(
            msg.sender,
            address(this),
            _debtToRepay
        );

        IERC20(_marketParams.loanToken).approve(address(MORPHO), _debtToRepay);

        (seizedCollateral, ) = MORPHO.liquidate(
            _marketParams,
            _borrower,
            0,
            sharesToRepay,
            ""
        );

        require(seizedCollateral >= _minCollateralOut, "Slippage exceeded");

        IERC20(_marketParams.collateralToken).transfer(
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

        uint256 maxDebtAssets = (uint256(borrowerCollateral) *
            IOracle(_marketParams.oracle).price() *
            1e18) / (lif * 1e36);

        uint256 sharesToLiquidate = (((maxDebtAssets *
            uint256(totalBorrowShares)) / uint256(totalBorrowAssets)) * 999) /
            1000;

        if (sharesToLiquidate > borrowerDebtShares)
            sharesToLiquidate = borrowerDebtShares;

        debtAssetsToLiquidate =
            (sharesToLiquidate * uint256(totalBorrowAssets)) /
            uint256(totalBorrowShares);
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
}
