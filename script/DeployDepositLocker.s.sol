// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Usage: source .env && forge script ./script/DeployDepositLocker.s.sol --rpc-url=$SEPOLIA_RPC_URL --broadcast --etherscan-api-key=$ETHERSCAN_API_KEY --verify

import "forge-std/Script.sol";

import { DepositLocker } from "src/core/DepositLocker.sol";

// Deployer
address constant CREATE2_FACTORY_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

// Deployment Configuration
address constant DEPOSIT_LOCKER_OWNER = 0x77777Cc68b333a2256B436D675E8D257699Aa667;
address constant RECIPE_MARKET_HUB = 0x783251f103555068c1E9D755f69458f39eD937c0;

contract DeployDepositLocker is Script { }
