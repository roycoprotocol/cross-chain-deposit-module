// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Import the PredepositExecutor contract and its dependencies
import {PredepositExecutor} from "src/PredepositExecutor.sol";
import { ERC20 } from "@royco/src/base/RecipeMarketHubBase.sol";

contract PredepositExecutorDeployScript is Script {
    // State variables for external contract addresses and arrays
    address public owner;
    address public weirollWalletImplementation;
    address public lzEndpoint;
    ERC20[] public predepositTokens;
    address[] public stargates;

    function setUp() public {
        // Initialize state variables

        // Set the owner address (can be set to the deployer or a specific address)
        owner = vm.envOr("OWNER", address(0)); // If not set, will default to deployer in run()

        // Set the Weiroll wallet implementation address on OP Sepolia
        weirollWalletImplementation = address(0x3a97Cd46442c1f6ddfd6A970d64649a20eaF2E17);

        // Set the LayerZero endpoint address
        lzEndpoint = address(0x6EDCE65403992e310A62460808c4b910D972f10f);

        // Initialize the arrays directly in the script
        // Example addresses for ERC20 tokens
        predepositTokens.push(ERC20(address(0x488327236B65C61A6c083e8d811a4E0D3d1D4268))); // USDC on OP Sepolia

        // Corresponding Stargate instances for each token
        stargates.push(address(0x1E8A86EcC9dc41106d3834c6F1033D86939B1e0D)); // StargatePoolUSDC on OP Sepolia
    }

    function run() public {
        // Fetch the deployer's private key from environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Use deployer as owner if owner is not set
        if (owner == address(0)) {
            owner = deployer;
        }

        // Ensure arrays have the same length
        require(
            predepositTokens.length == stargates.length, "Array lengths of predeposit tokens and stargates must match"
        );

        // Deploy the PredepositExecutor contract
        PredepositExecutor executor =
            new PredepositExecutor(owner, weirollWalletImplementation, lzEndpoint, predepositTokens, stargates);

        // Output the address of the deployed PredepositExecutor contract
        console.log("PredepositExecutor deployed at:", address(executor));

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
