// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Import the PredepositLocker contract and its dependencies
import { PredepositLocker, RecipeMarketHubBase, ERC20 } from "src/PredepositLocker.sol";
import { IStargate } from "src/interfaces/IStargate.sol";

contract PredepositLockerDeployScript is Script {
    // State variables for external contract addresses and arrays
    address public owner;
    uint32 public chainDstEid;
    address public predepositExecutor;
    ERC20[] public predepositTokens;
    IStargate[] public stargates;
    RecipeMarketHubBase public recipeMarketHub;

    function setUp() public {
        // Initialize state variables

        // Set the owner address (can be set to the deployer or a specific address)
        owner = vm.envOr("OWNER", address(0)); // If not set, will default to deployer in run()

        // Set the destination endpoint ID for the destination chain
        chainDstEid = uint32(40_232); // Destination endpoint for OP Sepolia

        // Set the address of the PredepositExecutor on OP Sepolia
        predepositExecutor = address(0xA03749F03c4cB7Bb8C2aa5f735BbdC776EF93014);

        // Initialize the arrays directly in the script
        // Example addresses for ERC20 tokens
        predepositTokens.push(ERC20(address(0x2F6F07CDcf3588944Bf4C42aC74ff24bF56e7590))); // USDC on ETH Sepolia

        // Corresponding Stargate instances for each token
        stargates.push(IStargate(address(0xa4e97dFd56E0E30A2542d666Ef04ACC102310083))); // StargatePoolUSDC on ETH Sepolia

        // Set the RecipeMarketHubBase contract address
        recipeMarketHub = RecipeMarketHubBase(address(0xb2215b4765515ad9d5Aa46B0D6EC3D8C91F45f2e)); // RecipeMarketHub on ETH Sepolia
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
        require(predepositTokens.length == stargates.length, "Array lengths of predeposit tokens and stargates must match");

        // Deploy the PredepositLocker contract
        PredepositLocker locker = new PredepositLocker(owner, chainDstEid, predepositExecutor, predepositTokens, stargates, recipeMarketHub);

        // Output the address of the deployed PredepositLocker contract
        console.log("PredepositLocker deployed at:", address(locker));

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
