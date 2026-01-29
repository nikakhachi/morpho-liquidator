// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMorpho, MarketParams, IOracle} from "./IMorpho.sol";

contract MorphoLiquidator {
    IMorpho morpho;

    constructor(address _morpho) {
        morpho = IMorpho(_morpho);
    }

    function liquidate(
        MarketParams memory _marketParams,
        address _borrower,
        uint256 _debtToRepay
    ) external {
        (
            uint128 borrowerDebtShares,
            ,
            ,
            uint128 totalBorrowShares
        ) = _positionData(_marketParams, _borrower);

        uint256 sharesToRepay = (_debtToRepay * uint256(borrowerDebtShares)) /
            uint256(totalBorrowShares);

        IERC20(_marketParams.loanToken).transferFrom(
            msg.sender,
            address(this),
            _debtToRepay
        );
        IERC20(_marketParams.loanToken).approve(
            address(morpho),
            type(uint256).max
        );

        (uint256 seizedCollateral, ) = morpho.liquidate(
            _marketParams,
            _borrower,
            0,
            sharesToRepay,
            ""
        );

        IERC20(_marketParams.collateralToken).transfer(
            msg.sender,
            seizedCollateral
        );
    }

    function maxDebtToRepay(
        MarketParams memory _marketParams,
        address _borrower,
        uint256 _liquidationPenalty // if 2.61%, pass 0.0261e18
    ) internal view returns (uint256 debtAssetsToLiquidate) {
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

        (, borrowerDebtShares, borrowerCollateral) = morpho.position(
            marketId,
            _borrower
        );
        (, , totalBorrowAssets, totalBorrowShares, , ) = morpho.market(
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
