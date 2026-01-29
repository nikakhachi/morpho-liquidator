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

    // =========================================================================
    //                          ORIGINAL TESTS (UNCHANGED)
    // =========================================================================

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

        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);

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

// =========================================================================
//                          EXTENDED TESTS
// =========================================================================

contract MorphoLiquidatorExtendedTest is Test {
    uint256 constant KATANA_CHAIN_ID = 747474;
    string constant KATANA_RPC = "https://rpc.katana.network/";

    address constant MORPHO = 0xD50F2DffFd62f94Ee4AEd9ca05C61d0753268aBc;
    address constant WS_RUSD = 0x4809010926aec940b550D34a46A52739f996D75D; // collateral
    address constant VB_USDC = 0x203A662b0BD271A6ed5a60EdFbd04bFce608FD36; // loan
    address constant ORACLE = 0xBc4bA30b95cF8de78065568c03853d597937807b;
    address constant IIRM = 0x4F708C0ae7deD3d74736594C2109C2E3c065B428;
    uint256 constant LLTV = 915000000000000000; // 91.5%

    uint256 constant LIF = 1.0261e18; // Liquidation Incentive Factor (2.61% penalty)

    IMorpho morpho;
    MorphoLiquidator liquidator;
    MarketParams marketParams;

    address constant BORROWER = 0x8297492D220371015398FD063382e827CF741070;

    function setUp() public {
        vm.createSelectFork(KATANA_RPC, 22953982);
        morpho = IMorpho(MORPHO);
        liquidator = new MorphoLiquidator(MORPHO);

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

    /// @notice Make the borrower underwater by mocking a lower oracle price
    function _makeUndercollateralized() internal returns (uint256 fakePrice) {
        fakePrice = (IOracle(ORACLE).price() * 9) / 10; // 10% price drop
        vm.mockCall(
            ORACLE,
            abi.encodeWithSelector(IOracle.price.selector),
            abi.encode(fakePrice)
        );
        morpho.accrueInterest(marketParams);
    }

    /// @notice Calculate max debt that can be liquidated for a position
    function _calculateMaxDebtToRepay(
        uint128 borrowerCollateral,
        uint256 oraclePrice,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint128 borrowerDebtShares
    ) internal pure returns (uint256 debtToRepay, uint256 sharesToLiquidate) {
        uint256 maxDebtAssets = (uint256(borrowerCollateral) *
            oraclePrice *
            1e18) / (LIF * 1e36);

        sharesToLiquidate =
            (((maxDebtAssets * uint256(totalBorrowShares)) /
                uint256(totalBorrowAssets)) * 999) /
            1000;

        if (sharesToLiquidate > borrowerDebtShares) {
            sharesToLiquidate = borrowerDebtShares;
        }

        debtToRepay =
            (sharesToLiquidate * uint256(totalBorrowAssets)) /
            uint256(totalBorrowShares);
    }

    // =========================================================================
    //                          BASIC FUNCTIONALITY TESTS
    // =========================================================================

    function testFork_BorrowerHasPosition() public view {
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        assertGt(borrowerDebtShares, 0, "Borrower should have debt");
        assertGt(borrowerCollateral, 0, "Borrower should have collateral");
    }

    function testLiquidate_BasicFunctionality() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 debtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 loanBefore = IERC20(VB_USDC).balanceOf(address(this));
        uint256 collateralBefore = IERC20(WS_RUSD).balanceOf(address(this));

        (uint256 seizedCollateral, uint256 repaidAssets) = liquidator.liquidate(
            marketParams,
            BORROWER,
            debtToRepay,
            0 // no min collateral
        );

        uint256 loanAfter = IERC20(VB_USDC).balanceOf(address(this));
        uint256 collateralAfter = IERC20(WS_RUSD).balanceOf(address(this));

        uint256 loanSpent = loanBefore - loanAfter;
        uint256 collateralReceived = collateralAfter - collateralBefore;

        assertGt(loanSpent, 0, "Should spend loan tokens");
        assertGt(collateralReceived, 0, "Should receive collateral");
        assertEq(loanSpent, debtToRepay, "Should spend exact debtToRepay");
        assertEq(seizedCollateral, collateralReceived, "Return value should match");
        assertEq(repaidAssets, loanSpent, "Repaid assets should match");

        console.log("MorphoLiquidator - vbUSDC Spent:", loanSpent);
        console.log("MorphoLiquidator - wsRUSD Received:", collateralReceived);
    }

    // =========================================================================
    //                          PARTIAL LIQUIDATION TESTS
    // =========================================================================

    function testLiquidate_PartialLiquidation_50Percent() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 maxDebtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        // Only liquidate 50% of max
        uint256 debtToRepay = maxDebtToRepay / 2;

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 collateralBefore = IERC20(WS_RUSD).balanceOf(address(this));

        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);

        uint256 collateralAfter = IERC20(WS_RUSD).balanceOf(address(this));
        uint256 collateralReceived = collateralAfter - collateralBefore;

        assertGt(collateralReceived, 0, "Should receive collateral");

        // Verify borrower still has remaining position
        (, uint128 remainingDebtShares, uint128 remainingCollateral) = morpho
            .position(_marketId(), BORROWER);
        assertGt(remainingDebtShares, 0, "Borrower should still have debt");
        assertGt(
            remainingCollateral,
            0,
            "Borrower should still have collateral"
        );

        console.log("50% Liquidation - wsRUSD Received:", collateralReceived);
        console.log("Borrower remaining debt shares:", remainingDebtShares);
    }

    function testLiquidate_PartialLiquidation_10Percent() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 maxDebtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        // Only liquidate 10%
        uint256 debtToRepay = maxDebtToRepay / 10;

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);

        // Verify borrower still has significant position
        (, uint128 remainingDebtShares, ) = morpho.position(
            _marketId(),
            BORROWER
        );
        assertGt(
            remainingDebtShares,
            (borrowerDebtShares * 8) / 10,
            "Borrower should have >80% debt remaining"
        );
    }

    // =========================================================================
    //                          MULTI-LIQUIDATION TESTS
    // =========================================================================

    function testLiquidate_MultipleLiquidations() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 maxDebtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        uint256 chunkSize = maxDebtToRepay / 4;

        deal(marketParams.loanToken, address(this), maxDebtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 totalCollateralReceived = 0;

        // Perform 4 liquidations
        for (uint256 i = 0; i < 4; i++) {
            uint256 collateralBefore = IERC20(WS_RUSD).balanceOf(address(this));
            liquidator.liquidate(marketParams, BORROWER, chunkSize, 0);
            uint256 collateralAfter = IERC20(WS_RUSD).balanceOf(address(this));
            totalCollateralReceived += (collateralAfter - collateralBefore);
        }

        assertGt(
            totalCollateralReceived,
            0,
            "Should receive collateral from multiple liquidations"
        );
        console.log(
            "Total wsRUSD from 4 liquidations:",
            totalCollateralReceived
        );
    }

    // =========================================================================
    //                          EDGE CASE TESTS
    // =========================================================================

    function testLiquidate_SmallAmount() public {
        morpho.accrueInterest(marketParams);
        _makeUndercollateralized();

        // Try liquidating a very small amount (1 USDC = 1e6)
        uint256 smallDebt = 1e6;

        deal(marketParams.loanToken, address(this), smallDebt * 10);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 collateralBefore = IERC20(WS_RUSD).balanceOf(address(this));

        liquidator.liquidate(marketParams, BORROWER, smallDebt, 0);

        uint256 collateralAfter = IERC20(WS_RUSD).balanceOf(address(this));

        // Even small liquidations should yield some collateral
        assertGt(
            collateralAfter,
            collateralBefore,
            "Should receive some collateral even for small liquidation"
        );
    }

    function testLiquidate_RevertWhenNotUndercollateralized() public {
        // Don't mock the price - position should be healthy
        morpho.accrueInterest(marketParams);

        deal(marketParams.loanToken, address(this), 1_000_000e6);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        // Should revert because position is healthy
        vm.expectRevert();
        liquidator.liquidate(marketParams, BORROWER, 1000e6, 0);
    }

    function testLiquidate_RevertWithZeroDebt() public {
        _makeUndercollateralized();

        deal(marketParams.loanToken, address(this), 1_000_000e6);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        // Zero debt should revert
        vm.expectRevert(MorphoLiquidator.ZeroAmount.selector);
        liquidator.liquidate(marketParams, BORROWER, 0, 0);
    }

    function testLiquidate_RevertWithInsufficientApproval() public {
        morpho.accrueInterest(marketParams);
        _makeUndercollateralized();

        uint256 debtToRepay = 1000e6;

        deal(marketParams.loanToken, address(this), debtToRepay);
        // No approval given

        vm.expectRevert();
        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);
    }

    function testLiquidate_RevertWithInsufficientBalance() public {
        morpho.accrueInterest(marketParams);
        _makeUndercollateralized();

        uint256 debtToRepay = 1000e6;

        // Don't deal any tokens - balance is 0
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        vm.expectRevert();
        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);
    }

    function testLiquidate_RevertWithNonExistentBorrower() public {
        _makeUndercollateralized();

        address fakeBorrower = address(0xdead);

        deal(marketParams.loanToken, address(this), 1_000_000e6);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        // Should revert because borrower has no position
        vm.expectRevert();
        liquidator.liquidate(marketParams, fakeBorrower, 1000e6, 0);
    }

    function testLiquidate_RevertWithInvalidMarket() public {
        _makeUndercollateralized();

        MarketParams memory invalidMarket = MarketParams({
            loanToken: address(0x1234),
            collateralToken: address(0x5678),
            oracle: ORACLE,
            irm: IIRM,
            lltv: LLTV
        });

        deal(marketParams.loanToken, address(this), 1_000_000e6);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        vm.expectRevert();
        liquidator.liquidate(invalidMarket, BORROWER, 1000e6, 0);
    }

    // =========================================================================
    //                          SLIPPAGE PROTECTION TESTS
    // =========================================================================

    function testLiquidate_SlippageProtection_Success() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 debtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        // Set a reasonable minimum (should pass)
        uint256 minCollateralOut = 1e18; // 1 wsRUSD minimum

        (uint256 seized, ) = liquidator.liquidate(
            marketParams,
            BORROWER,
            debtToRepay,
            minCollateralOut
        );

        assertGt(seized, minCollateralOut, "Should receive more than minimum");
    }

    function testLiquidate_SlippageProtection_Revert() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 debtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        // Set an impossibly high minimum (should revert)
        uint256 minCollateralOut = type(uint256).max;

        vm.expectRevert(MorphoLiquidator.SlippageExceeded.selector);
        liquidator.liquidate(
            marketParams,
            BORROWER,
            debtToRepay,
            minCollateralOut
        );
    }

    // =========================================================================
    //                          CALLER TESTS
    // =========================================================================

    function testLiquidate_DifferentCallers() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 maxDebtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        uint256 debtToRepay = maxDebtToRepay / 3;

        // Caller 1
        address caller1 = address(0xCAFE);
        deal(marketParams.loanToken, caller1, debtToRepay * 2);
        vm.startPrank(caller1);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );
        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);
        vm.stopPrank();

        uint256 caller1Collateral = IERC20(WS_RUSD).balanceOf(caller1);
        assertGt(caller1Collateral, 0, "Caller1 should receive collateral");

        // Caller 2
        address caller2 = address(0xBEEF);
        deal(marketParams.loanToken, caller2, debtToRepay * 2);
        vm.startPrank(caller2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );
        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);
        vm.stopPrank();

        uint256 caller2Collateral = IERC20(WS_RUSD).balanceOf(caller2);
        assertGt(caller2Collateral, 0, "Caller2 should receive collateral");

        console.log("Caller1 wsRUSD:", caller1Collateral);
        console.log("Caller2 wsRUSD:", caller2Collateral);
    }

    // =========================================================================
    //                          PROFITABILITY TESTS
    // =========================================================================

    function testLiquidate_IsProfitable() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 debtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 loanBefore = IERC20(VB_USDC).balanceOf(address(this));

        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);

        uint256 loanAfter = IERC20(VB_USDC).balanceOf(address(this));
        uint256 collateralReceived = IERC20(WS_RUSD).balanceOf(address(this));

        uint256 loanSpent = loanBefore - loanAfter;

        // Calculate value of collateral received at current (mocked) price
        // collateralValue = collateral * price / 1e36 (price is scaled)
        uint256 collateralValueInLoanToken = (collateralReceived * fakePrice) /
            1e36;

        // Liquidation should be profitable (collateral value > loan spent)
        // The LIF (1.0261) means we get 2.61% more collateral than debt repaid
        assertGt(
            collateralValueInLoanToken,
            loanSpent,
            "Liquidation should be profitable"
        );

        uint256 profit = collateralValueInLoanToken - loanSpent;
        uint256 profitBps = (profit * 10000) / loanSpent;

        console.log("Loan spent (USDC):", loanSpent);
        console.log("Collateral value (USDC equivalent):", collateralValueInLoanToken);
        console.log("Profit (USDC equivalent):", profit);
        console.log("Profit (bps):", profitBps);
    }

    // =========================================================================
    //                          GAS USAGE TESTS
    // =========================================================================

    function testLiquidate_GasUsage() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 debtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 gasBefore = gasleft();
        liquidator.liquidate(marketParams, BORROWER, debtToRepay, 0);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for liquidation:", gasUsed);

        // Sanity check - liquidation shouldn't use excessive gas
        assertLt(gasUsed, 500_000, "Gas usage should be reasonable");
    }

    // =========================================================================
    //                          COMPARISON: DIRECT vs LIQUIDATOR
    // =========================================================================

    function testLiquidate_CompareDirectVsLiquidator() public {
        // ---- Direct Morpho liquidation ----
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (
            uint256 debtToRepay,
            uint256 sharesToLiquidate
        ) = _calculateMaxDebtToRepay(
                borrowerCollateral,
                fakePrice,
                totalBorrowAssets,
                totalBorrowShares,
                borrowerDebtShares
            );

        // Use only half to leave room for second liquidation
        uint256 halfDebt = debtToRepay / 2;
        uint256 halfShares = sharesToLiquidate / 2;

        deal(marketParams.loanToken, address(this), halfDebt * 4);
        IERC20(marketParams.loanToken).approve(MORPHO, type(uint256).max);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        // Direct Morpho liquidation
        uint256 directLoanBefore = IERC20(VB_USDC).balanceOf(address(this));
        uint256 directCollateralBefore = IERC20(WS_RUSD).balanceOf(address(this));
        morpho.liquidate(marketParams, BORROWER, 0, halfShares, "");
        uint256 directLoanAfter = IERC20(VB_USDC).balanceOf(address(this));
        uint256 directCollateralAfter = IERC20(WS_RUSD).balanceOf(address(this));

        uint256 directLoanSpent = directLoanBefore - directLoanAfter;
        uint256 directCollateral = directCollateralAfter - directCollateralBefore;

        // MorphoLiquidator liquidation
        uint256 liquidatorLoanBefore = IERC20(VB_USDC).balanceOf(address(this));
        uint256 liquidatorCollateralBefore = IERC20(WS_RUSD).balanceOf(address(this));
        liquidator.liquidate(marketParams, BORROWER, halfDebt, 0);
        uint256 liquidatorLoanAfter = IERC20(VB_USDC).balanceOf(address(this));
        uint256 liquidatorCollateralAfter = IERC20(WS_RUSD).balanceOf(address(this));

        uint256 liquidatorLoanSpent = liquidatorLoanBefore - liquidatorLoanAfter;
        uint256 liquidatorCollateral = liquidatorCollateralAfter - liquidatorCollateralBefore;

        console.log("=== Direct Morpho ===");
        console.log("Loan spent:", directLoanSpent);
        console.log("Collateral received:", directCollateral);

        console.log("=== MorphoLiquidator ===");
        console.log("Loan spent:", liquidatorLoanSpent);
        console.log("Collateral received:", liquidatorCollateral);

        // Both should have received collateral
        assertGt(directCollateral, 0, "Direct should receive collateral");
        assertGt(liquidatorCollateral, 0, "Liquidator should receive collateral");
    }

    // =========================================================================
    //                          RETURN VALUE TESTS
    // =========================================================================

    function testLiquidate_ReturnsCorrectValues() public {
        morpho.accrueInterest(marketParams);
        (, uint128 borrowerDebtShares, uint128 borrowerCollateral) = morpho
            .position(_marketId(), BORROWER);
        (, , uint128 totalBorrowAssets, uint128 totalBorrowShares, , ) = morpho
            .market(_marketId());

        uint256 fakePrice = _makeUndercollateralized();

        (uint256 debtToRepay, ) = _calculateMaxDebtToRepay(
            borrowerCollateral,
            fakePrice,
            totalBorrowAssets,
            totalBorrowShares,
            borrowerDebtShares
        );

        deal(marketParams.loanToken, address(this), debtToRepay * 2);
        IERC20(marketParams.loanToken).approve(
            address(liquidator),
            type(uint256).max
        );

        uint256 loanBefore = IERC20(VB_USDC).balanceOf(address(this));
        uint256 collateralBefore = IERC20(WS_RUSD).balanceOf(address(this));

        (uint256 seizedCollateral, uint256 repaidAssets) = liquidator.liquidate(
            marketParams,
            BORROWER,
            debtToRepay,
            0
        );

        uint256 loanAfter = IERC20(VB_USDC).balanceOf(address(this));
        uint256 collateralAfter = IERC20(WS_RUSD).balanceOf(address(this));

        uint256 actualLoanSpent = loanBefore - loanAfter;
        uint256 actualCollateralReceived = collateralAfter - collateralBefore;

        // Return values should match actual balance changes
        assertEq(
            seizedCollateral,
            actualCollateralReceived,
            "Seized collateral return should match balance"
        );
        assertEq(
            repaidAssets,
            actualLoanSpent,
            "Repaid assets return should match balance"
        );
    }

    // =========================================================================
    //                          MAX DEBT TO REPAY VIEW FUNCTION TESTS
    // =========================================================================

    function testMaxDebtToRepay_ReturnsValue() public {
        morpho.accrueInterest(marketParams);
        _makeUndercollateralized();

        uint256 liquidationPenalty = 0.0261e18; // 2.61%
        uint256 maxDebt = liquidator.maxDebtToRepay(
            marketParams,
            BORROWER,
            liquidationPenalty
        );

        assertGt(maxDebt, 0, "Max debt should be > 0 for underwater position");
        console.log("Max debt to repay:", maxDebt);
    }

    function testMaxDebtToRepay_HealthyPosition() public view {
        // Don't make undercollateralized - position is healthy
        uint256 liquidationPenalty = 0.0261e18;

        // For a healthy position, this should still return a value
        // (the calculation doesn't check if position is actually liquidatable)
        uint256 maxDebt = liquidator.maxDebtToRepay(
            marketParams,
            BORROWER,
            liquidationPenalty
        );

        // Should return some value based on collateral
        assertGt(maxDebt, 0, "Should return calculation even for healthy position");
    }

    // =========================================================================
    //                          CONSTRUCTOR TESTS
    // =========================================================================

    function testConstructor_SetsMorphoAddress() public view {
        assertEq(
            address(liquidator.MORPHO()),
            MORPHO,
            "MORPHO address should be set"
        );
    }

    function testConstructor_ZeroAddress() public {
        // Deploying with zero address - contract deploys but will fail on use
        MorphoLiquidator badLiquidator = new MorphoLiquidator(address(0));
        assertTrue(address(badLiquidator) != address(0), "Should deploy");

        // Attempting to use it should fail
        _makeUndercollateralized();
        deal(marketParams.loanToken, address(this), 1000e6);
        IERC20(marketParams.loanToken).approve(
            address(badLiquidator),
            type(uint256).max
        );

        vm.expectRevert();
        badLiquidator.liquidate(marketParams, BORROWER, 100e6, 0);
    }
}
