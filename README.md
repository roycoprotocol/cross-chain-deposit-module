# Chain Predeposit Module

The Chain Predeposit Module (CPM) is a sophisticated system designed to facilitate cross-chain deposits and executions for decentralized applications. It consists of two main components: the PredepositLocker on the source chain and the PredepositExecutor on the destination chain.

## Overview

This module allows users to deposit funds on one chain and have those funds bridged and utilized on another chain according to predefined recipes. It leverages LayerZero for cross-chain communication and Stargate for token bridging.

### Key Components

1. **PredepositLocker**: Deployed on the source chain
   - Manages deposits from users
   - Handles bridging of funds to the destination chain
   - Integrates with RecipeMarketHub for market creation and management

2. **PredepositExecutor**: Deployed on the destination chain
   - Receives bridged funds
   - Creates Weiroll wallets for depositors
   - Executes deposit and withdrawal recipes

3. **WeirollWallet**: Smart contract wallets used to execute recipes
   - Used on the source chain to deposit funds to bridge and withdraw funds (rage quit)
   - Used on the destination chain to execute deposits upon bridge and withdrawals after an absolute locktime

## Key Features

- Cross-chain deposits and executions
- Customizable deposit and withdrawal recipes
- Integration with RecipeMarketHub for market management
- Secure bridging using LayerZero and Stargate
- Flexible locking mechanisms for deposited funds

## Contract Interactions

1. Users deposit funds into the PredepositLocker on the source chain through their Weiroll Wallet
2. Depositors can withdraw deposits anytime before their deposits are bridged
2. PredepositLocker bridges funds to the destination chain
3. PredepositExecutor receives bridged funds and creates Weiroll Wallets for each depositor
4. Deposit recipes are executed on the destination chain
5. Users can withdraw funds after the absolute unlock timestamp