// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Launchpad} from "../src/Launchpad.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address weth = vm.envAddress("WETH"); // Base: 0x4200000000000000000000000000000000000006
        address uniFactory = vm.envAddress("UNI_V2_FACTORY"); // copy from Uniswap's official deployment docs
        address treasury = vm.envAddress("TREASURY"); // use a multisig (Safe) on mainnet
        uint256 creationFee = vm.envOr("CREATION_FEE", uint256(0));

        vm.startBroadcast(pk);
        Launchpad lp = new Launchpad(weth, uniFactory, treasury, creationFee);
        vm.stopBroadcast();

        console.log("Launchpad deployed at:", address(lp));
    }
}
