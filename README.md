# Cross-Chain Deposit Module (CCDM) [![Tests](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml/badge.svg)](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml)

The Cross-Chain Deposit Module (CCDM) is a sophisticated system designed to facilitate cross-chain deposit campaigns for protocols that want users (APs) to commit liquidity from a source chain into protocols on a destination chain. It consists of two main components: the ```DepositLocker``` on the source chain and the ```DepositExecutor``` on the destination chain.

## Overview

This module allows users to deposit funds on one chain (source) and have those funds bridged and utilized on another chain (destination) according to market specific recipes. It leverages [LayerZero](https://layerzero.network) for cross-chain communication and token bridging. The system supports all tokens that abide to the [OFT](https://docs.layerzero.network/v2/home/token-standards/oft-standard) standard.

### Key Components

1. **[RecipeMarketHub](https://github.com/roycoprotocol/royco/blob/main/src/RecipeMarketHub.sol)**: A hub for all interactions between APs and IPs on Royco
   - Permissionless market creation, offer creation, and offer filling
   - Creation of Weiroll Wallets and automatic execution of deposit recipes for APs upon filling an offer
   - Allows APs to execute withdrawal recipes to reclaim their funds as per the market's parameters

1. **[WeirollWallet](https://github.com/roycoprotocol/royco/blob/main/src/WeirollWallet.sol)**: Smart contract wallets used to execute recipes
   - Used on the source chain to deposit funds for bridging and withdraw funds (rage quit) to/from the DepositLocker
   - Used on the destination chain to hold a depositor's position, execute destination deposit recipes upon bridging, and withdrawals after an absolute locktime

2. **[DepositLocker](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/DepositLocker.sol)**: Deployed on the source chain
   - Integrates with Royco's RecipeMarketHub to facilitate deposits and withdrawals
   - Accepts deposits from users' Weiroll Wallets upon an AP filling an offer in any Deposit market
   - Allows for withdrawals until deposits are bridged
   - Handles bridging funds to the destination chain in addition to destination execution parameters via LayerZero

3. **[DepositExecutor](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/DepositExecutor.sol)**: Deployed on the destination chain
   - Receives the bridged funds and parameters via LayerZero and atomically creates Weiroll Wallets for all bridged depositors
   - Executes deposit scripts ONCE after bridge (either by the depositor or the owner of the cross-chain deposit campaign)
   - Allows the depositor to execute the withdrawal recipe after the absolute locktime has passed

## Key Features

- Integration with RecipeMarketHub for market management, offer creation and fulfillment, and Weiroll Wallet executions on the source chain
- Bridging funds and a payload containing depositor information using LayerZero
- Weiroll Wallets created for each depositor on the destination chain with the ability to deposit and withdraw assets as specified by the campaign's destination recipes

## CCDM Flow
1. AP (depositor) fills an offer for a cross-chain deposit market in the RecipeMarketHub
2. The RecipeMarketHub automatically creates a Weiroll Wallet for the user and deposits them into the DepositLocker
3. Depositors can withdraw deposits anytime through the RecipeMarketHub before their deposits are bridged
4. Once green light is given, anyone can bridge funds to the destination chain from the DepositLocker
5. DepositExecutor receives bridged funds and creates Weiroll Wallets for each depositor as per the bridged execution parameters
6. Destination deposit recipes are executed on the destination chain
7. Users can withdraw funds through the DepositExecutor after the absolute unlock timestamp
