// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Import the PredepositLocker contract and its dependencies
import {PredepositLocker} from "src/PredepositLocker.sol";
import {RecipeKernelBase} from "src/base/RecipeKernelBase.sol";
import {IStargate} from "src/interfaces/IStargate.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

contract PredepositLockerDeployScript is Script {
    // State variables for external contract addresses and arrays
    address public owner;
    uint32 public chainDstEid;
    address public predepositExecutor;
    ERC20[] public predepositTokens;
    IStargate[] public stargates;
    RecipeKernelBase public recipeKernel;

    function setUp() public {
        // Initialize state variables

        // Set the owner address (can be set to the deployer or a specific address)
        owner = vm.envOr("OWNER", address(0)); // If not set, will default to deployer in run()

        // Set the destination endpoint ID for the destination chain
        chainDstEid = uint32(40232); // Destination endpoint for OP Sepolia

        // Set the address of the PredepositExecutor on the destination chain
        predepositExecutor = vm.envOr("PREDEPOSIT_EXECUTOR", address(0x0));

        // Initialize the arrays directly in the script
        // Example addresses for ERC20 tokens
        predepositTokens.push(ERC20(address(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238))); // USDC on ETH Sepolia

        // Corresponding Stargate instances for each token
        stargates.push(IStargate(address(0xa5A8481790BB57CF3FA0a4f24Dc28121A491447f))); // StargatePoolUSDC on ETH Sepolia

        // Set the RecipeKernelBase contract address
        recipeKernel = RecipeKernelBase(address(0xb2215b4765515ad9d5Aa46B0D6EC3D8C91F45f2e)); // RecipeKernel on ETH Sepolia
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

        // Deploy the PredepositLocker contract
        PredepositLocker locker =
            new PredepositLocker(owner, chainDstEid, predepositExecutor, predepositTokens, stargates, recipeKernel);

        // Output the address of the deployed PredepositLocker contract
        console.log("PredepositLocker deployed at:", address(locker));

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
