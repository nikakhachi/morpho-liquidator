// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {MarketParams, IMorpho} from "../src/IMorpho.sol";
import {MorphoLiquidator} from "../src/MorphoLiquidator.sol";
import {console} from "forge-std/console.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);

    function transfer(address, uint256) external returns (bool);

    function approve(address, uint256) external returns (bool);

    function decimals() external view returns (uint8);
}

interface IOracle {
    function price() external view returns (uint256);
}

contract MorphoLiquidationTest is Test {
    uint256 constant KATANA_CHAIN_ID = 747474;
    string constant KATANA_RPC = "https://rpc.katana.network/";

    address constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    address constant WS_RUSD = 0x4809010926aec940b550D34a46A52739f996D75D; // collateral
    address constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36; // loan
    address constant ORACLE = 0xBc4bA30b95cF8de78065568c03853d597937807b;
    address constant IIRM = 0x4F708C0ae7deD3d74736594C2109C2E3c065B428;
    uint256 constant LLTV = 915000000000000000; // 91.5% in basis points

    IMorpho morpho;
    MarketParams marketParams;

    function setUp() public {
        // Fork Katana mainnet (chain ID 747474). Use a recent block for reproducible tests.
        vm.createSelectFork(KATANA_RPC, 22953982);
        morpho = IMorpho(MORPHO);

        marketParams = MarketParams({
            loanToken: VB_USDC,
            collateralToken: WS_RUSD,
            oracle: ORACLE,
            irm: IIRM,
            lltv: LLTV
        });
    }

    function _marketId() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    marketParams.loanToken,
                    marketParams.collateralToken,
                    marketParams.oracle,
                    marketParams.irm,
                    marketParams.lltv
                )
            );
    }

    function testFork_MarketExists() public view {
        bytes32 id = _marketId();
        (uint128 totalSupplyAssets, , , , , ) = morpho.market(id);
        assertGt(totalSupplyAssets, 0, "Market should have supply");
    }

    function testLiquidate_ExistingBorrower() public {
        address BORROWER = 0x8297492D220371015398FD063382e827CF741070;

        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = (IOracle(ORACLE).price() * 9) / 10;
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.price.selector),
            abi.encode(fakePrice)
        );
        morpho.accrueInterest(marketParams);

        uint256 lif = 1.0261e18; // Liquidation penalty is 2.61% → liquidation incentive factor = 1.0261

        uint256 maxDebtAssets = (uint256(borrowerCollateral) *
            fakePrice *
            1e18) / (lif * 1e36);
        uint256 sharesToLiquidate = (((maxDebtAssets *
            uint256(totalBorrowShares)) / uint256(totalBorrowAssets)) * 999) /
            1000;

        if (sharesToLiquidate > borrowerDebtShares)
            sharesToLiquidate = borrowerDebtShares;

        deal(marketParams.loanToken, address(this), 2_000_000e6);
        IERC20(marketParams.loanToken).approve(MORPHO, type(uint256).max);

        uint256 liquidatorLoanBefore = IERC20(VB_USDC).balanceOf(address(this));
        uint256 liquidatorCollateralBefore = IERC20(WS_RUSD).balanceOf(
            address(this)
        );

        morpho.liquidate(marketParams, BORROWER, 0, sharesToLiquidate, "");

        uint256 liquidatorLoanAfter = IERC20(VB_USDC).balanceOf(address(this));
        uint256 liquidatorCollateralAfter = IERC20(WS_RUSD).balanceOf(
            address(this)
        );

        console.log(
            "vbUSDC Spent: ",
            liquidatorLoanBefore - liquidatorLoanAfter
        );
        console.log(
            "wsRUSD Received: ",
            liquidatorCollateralAfter - liquidatorCollateralBefore
        );
    }

    function testLiquidate_ThroughMorphoLiquidator() public {
        address BORROWER = 0x8297492D220371015398FD063382e827CF741070;

        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = (IOracle(ORACLE).price() * 9) / 10;
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.price.selector),
            abi.encode(fakePrice)
        );
        morpho.accrueInterest(marketParams);

        uint256 lif = 1.0261e18;

        uint256 maxDebtAssets = (uint256(borrowerCollateral) *
            fakePrice *
            1e18) / (lif * 1e36);
        uint256 sharesToLiquidate = (((maxDebtAssets *
            uint256(totalBorrowShares)) / uint256(totalBorrowAssets)) * 999) /
            1000;

        if (sharesToLiquidate > borrowerDebtShares)
            sharesToLiquidate = borrowerDebtShares;

        uint256 debtToRepay = (sharesToLiquidate * uint256(totalBorrowAssets)) /
            uint256(totalBorrowShares);

        MorphoLiquidator liquidator = new MorphoLiquidator(MORPHO);

        deal(marketParams.loanToken, address(this), 2_000_000e6);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 liquidatorLoanBefore = IERC20(VB_USDC).balanceOf(address(this));
        uint256 liquidatorCollateralBefore = IERC20(WS_RUSD).balanceOf(
            address(this)
        );

        liquidator.liquidate(marketParams, BORROWER, debtToRepay);

        uint256 liquidatorLoanAfter = IERC20(VB_USDC).balanceOf(address(this));
        uint256 liquidatorCollateralAfter = IERC20(WS_RUSD).balanceOf(
            address(this)
        );

        console.log(
            "vbUSDC Spent (via MorphoLiquidator): ",
            liquidatorLoanBefore - liquidatorLoanAfter
        );
        console.log(
            "wsRUSD Received (via MorphoLiquidator): ",
            liquidatorCollateralAfter - liquidatorCollateralBefore
        );
    }
}
