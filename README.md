# Cross-Chain Deposit Module

The Cross-Chain Deposit Module (CDM) is a sophisticated system designed to facilitate cross-chain deposit campaigns for chains that want users to commit liquidity from the source chain into their protocols on the destination chain. It consists of two main components: the ```DepositLocker``` on the source chain and the ```DepositExecutor``` on the destination chain.

## Overview

This module allows users to deposit funds on one chain and have those funds bridged and utilized on another chain according to market specific recipes. It leverages LayerZero for cross-chain communication and token bridging.

### Key Components

1. **[RecipeMarketHub](https://github.com/roycoprotocol/royco/blob/main/src/RecipeMarketHub.sol)**: A hub for all interactions between APs and IPs on Royco
   - Permissionless market creation, offer creation, and offer filling
   - Handles creation of Weiroll Wallets and automatic execution of deposit recipes for APs upon filling an offer
   - Allows APs to execute withdraw recipes to reclaim their funds as per the market's parameters

1. **[WeirollWallet](https://github.com/roycoprotocol/royco/blob/main/src/WeirollWallet.sol)**: Smart contract wallets used to execute recipes
   - Used on the source chain to deposit funds to bridge and withdraw funds (rage quit) to/from the DepositLocker
   - Used on the destination chain to hold a depositor's position, execute deposits upon bridging, and withdrawals after an absolute locktime

2. **[DepositLocker](https://github.com/roycoprotocol/chain-Deposit-module/blob/main/src/DepositLocker.sol)**: Deployed on the source chain
   - Integrates with Royco's RecipeMarketHub to facilitate deposits and withdrawals
   - Accepts deposits from users' Weiroll Wallets upon an AP filling an offer in any Deposit market
   - Allows for withdrawals until deposits are bridged
   - Handles bridging funds to the destination chain in addition to composing destination execution logic via LayerZero

3. **[DepositExecutor](https://github.com/roycoprotocol/chain-Deposit-module/blob/main/src/DepositExecutor.sol)**: Deployed on the destination chain
   - Receives the bridged funds and composed payload via LayerZero and atomically creates Weiroll Wallets for all bridged depositors
   - Executes deposit scripts ONCE after bridge (either by the depositor or the owner of the Deposit campaign)
   - Allows the depositor to execute the withdrawal recipe after the absolute locktime has passed

## Key Features

- Integration with RecipeMarketHub for market management, offer creation and fulfillment, and Weiroll Wallet executions on the source chain
- Bridging funds and a payload containing depositor information using LayerZero
- Weiroll Wallets created for each depositor on the destination chain with the ability to deposit and withdraw assets as specified by the campaign's recipes

## CPM Flow
1. AP (depositor) fills an offer for a Deposit market in the RecipeMarketHub
2. The RecipeMarketHub automatically creates a Weiroll Wallet for the user and deposits them into the DepositLocker
3. Depositors can withdraw deposits anytime through the RecipeMarketHub before their deposits are bridged
4. Once green light is given, anyone can bridge funds to the destination chain from the DepositLocker
5. DepositExecutor receives bridged funds and creates Weiroll Wallets for each depositor based on data in composed payload
6. Deposit recipes are executed on the destination chain
7. Users can withdraw funds after the absolute unlock timestamp