# Chain Predeposit Module

The Chain Predeposit Module (CPM) is a sophisticated system designed to facilitate predeposit campaigns for chains that want to have pre-committed liquidity into their protocols on day one. It consists of two main components: the ```PredepositLocker``` on the source chain and the ```PredepositExecutor``` on the destination chain.

## Overview

This module allows users to deposit funds on one chain and have those funds bridged and utilized on another chain according to market specific recipes. It leverages LayerZero for cross-chain communication and token bridging.

### Key Components

1. **[RecipeMarketHub](https://github.com/roycoprotocol/royco/blob/main/src/RecipeMarketHub.sol)**: A hub for all interactions between APs and IPs on Royco
   - Permissionless market creation, offer creation, and offer filling
   - Handles creation of Weiroll Wallets and automatic execution of deposit recipes for APs upon filling an offer
   - Allows APs to execute withdraw recipes to reclaim their funds as per the market's parameters

1. **[WeirollWallet](https://github.com/roycoprotocol/royco/blob/main/src/WeirollWallet.sol)**: Smart contract wallets used to execute recipes
   - Used on the source chain to deposit funds to bridge and withdraw funds (rage quit) to/from the PredepositLocker
   - Used on the destination chain to hold a depositor's position, execute deposits upon bridging, and withdrawals after an absolute locktime

2. **[PredepositLocker](https://github.com/roycoprotocol/chain-predeposit-module/blob/main/src/PredepositLocker.sol)**: Deployed on the source chain
   - Integrates with Royco's RecipeMarketHub to facilitate deposits and withdrawals
   - Accepts deposits from users' Weiroll Wallets upon an AP filling an offer in any predeposit market
   - Allows for withdrawals until deposits are bridged
   - Handles bridging funds to the destination chain in addition to composing destination execution logic via LayerZero

3. **[PredepositExecutor](https://github.com/roycoprotocol/chain-predeposit-module/blob/main/src/PredepositExecutor.sol)**: Deployed on the destination chain
   - Receives the bridged funds and composed payload via LayerZero and atomically creates Weiroll Wallets for all bridged depositors
   - Executes deposit scripts ONCE after bridge (either by the depositor or the owner of the predeposit campaign)
   - Allows the depositor to execute the withdrawal recipe after the absolute locktime has passed

## Key Features

- Integration with RecipeMarketHub for market management, offer creation and fulfillment, and Weiroll Wallet executions
- Bridging funds and a composed payload using LayerZero
- Customizable deposit and withdrawal recipes on the destination chain
- Flexible locking mechanisms for deposited funds

## CPM Flow
1. AP (depositor) fills an offer for a predeposit market in the RecipeMarketHub
2. The RecipeMarketHub automatically creates a Weiroll Wallet for the user and deposits them into the PredepositLocker
3. Depositors can withdraw deposits anytime through the RecipeMarketHub before their deposits are bridged
4. Once green light is given, anyone can bridge funds to the destination chain from the PredepositLocker
5. PredepositExecutor receives bridged funds and creates Weiroll Wallets for each depositor based on data in composed payload
6. Deposit recipes are executed on the destination chain
7. Users can withdraw funds after the absolute unlock timestamp