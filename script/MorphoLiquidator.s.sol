// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {MorphoLiquidator} from "../src/MorphoLiquidator.sol";

address constant MORPHO = 0x0000000000000000000000000000000000000000;

contract MorphoLiquidatorScript is Script {
    MorphoLiquidator public liquidator;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        liquidator = new MorphoLiquidator(MORPHO);

        vm.stopBroadcast();
    }
}
