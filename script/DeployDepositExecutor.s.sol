// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Import the DepositExecutor contract and its dependencies
import "src/core/DepositExecutor.sol";

contract DepositExecutorDeployScript is Script {
    // State variables for external contract addresses and arrays
    address public owner;
    address public weirollWalletImplementation;
    address public lzEndpoint;
    ERC20[] public depositTokens;
    address[] public lzV2OFTs;

    function setUp() public {
        // Initialize state variables

        // Set the owner address (can be set to the deployer or a specific address)
        owner = vm.envOr("OWNER", address(0)); // If not set, will default to deployer in run()

        // Set the Weiroll wallet implementation address on ARB Sepolia
        weirollWalletImplementation = address(0x3e011b0A7504ad303478Ed0b204fbD551653bda2);

        // Set the LayerZero endpoint address for ARB Sepolia
        lzEndpoint = address(0x6EDCE65403992e310A62460808c4b910D972f10f);

        // Initialize the arrays directly in the script
        // Example addresses for ERC20 tokens
        depositTokens.push(ERC20(address(0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773))); // USDC on ARB Sepolia

        // Corresponding Stargate instances for each token
        lzV2OFTs.push(address(0x543BdA7c6cA4384FE90B1F5929bb851F52888983)); // StargatePoolUSDC on ARB Sepolia
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
        require(depositTokens.length == lzV2OFTs.length, "Array lengths of deposit tokens and lzV2OFTs must match");

        // Deploy the DepositExecutor contract
        DepositExecutor executor = new DepositExecutor(owner, lzEndpoint, owner);

        // Output the address of the deployed DepositExecutor contract
        console.log("DepositExecutor deployed at:", address(executor));

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
}
