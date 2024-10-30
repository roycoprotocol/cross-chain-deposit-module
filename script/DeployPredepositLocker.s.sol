// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Import the PredepositLocker contract and its dependencies
import "src/PredepositLocker.sol";

contract PredepositLockerDeployScript is Script {
    // State variables for external contract addresses and arrays
    address public owner;
    uint32 public chainDstEid;
    address public predepositExecutor;
    ERC20[] public predepositTokens;
    IOFT[] public lzOApps;
    RecipeMarketHubBase public recipeMarketHub;

    function setUp() public {
        // Initialize state variables

        // Set the owner address (can be set to the deployer or a specific address)
        owner = vm.envOr("OWNER", address(0)); // If not set, will default to deployer in run()

        // Set the destination endpoint ID for the destination chain
        chainDstEid = uint32(40_231); // LZv2 destination endpoint for ARB Sepolia

        // Set the address of the PredepositExecutor on ARB Sepolia
        predepositExecutor = address(0xD6414b9Edb3d2C8345dDd37aB244eC4557a90394);

        // Initialize the arrays directly in the script
        // Example addresses for ERC20 tokens
        predepositTokens.push(ERC20(address(0x488327236B65C61A6c083e8d811a4E0D3d1D4268))); // USDC on OP Sepolia

        // Corresponding Stargate instances for each token
        lzOApps.push(IOFT(address(0x314B753272a3C79646b92A87dbFDEE643237033a))); // StargatePoolUSDC on OP Sepolia

        // Set the RecipeMarketHubBase contract address
        recipeMarketHub = RecipeMarketHubBase(address(0x828223B512BF1892229FeC61C5c1376BDED3a285)); // RecipeMarketHub on OP Sepolia
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
        require(predepositTokens.length == lzOApps.length, "Array lengths of predeposit tokens and lzOApps must match");

        // Deploy the PredepositLocker contract
        PredepositLocker locker = new PredepositLocker(owner, chainDstEid, predepositExecutor, recipeMarketHub, predepositTokens, lzOApps);

        // Output the address of the deployed PredepositLocker contract
        console.log("PredepositLocker deployed at:", address(locker));

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
