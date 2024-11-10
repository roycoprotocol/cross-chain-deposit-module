# Cross-Chain Deposit Module (CCDM) [![Tests](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml/badge.svg)](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml)

The Cross-Chain Deposit Module (CCDM) is a sophisticated system designed to facilitate cross-chain deposit campaigns. Protocols can incentivize users to commit liquidity on any chain into agreed upon actions (supplying, LPing, swapping, etc.) on a destination chain. CCDM consists of two main components: the **Deposit Locker** on the source chain and the **Deposit Executor** on the destination chain.

## CCDM Technical Overview

CCDM allows users to deposit funds on one chain (source) and have those funds bridged and utilized on another chain (destination) according to campaign specific action logic. It leverages [LayerZero](https://layerzero.network) V2 for cross-chain communication and token bridging. The system supports all tokens that can be bridged using LayerZero V2's [OFT](https://docs.layerzero.network/v2/home/token-standards/oft-standard) standard.

### Key Components

1. **[RecipeMarketHub](https://github.com/roycoprotocol/royco/blob/main/src/RecipeMarketHub.sol)**: A hub for all recipe market interactions between APs and IPs on Royco
   - Permissionless market creation and offer creation, negotiation, and filling
   - Atomic Weiroll Wallet creation and execution of deposit recipes upon an offer being filled.
   - Allows APs to execute withdrawal recipes to reclaim their funds.

1. **[WeirollWallet](https://github.com/roycoprotocol/royco/blob/main/src/WeirollWallet.sol)**: Smart contract wallets (owned by depositors) used to execute recipes
   - Used on the source chain to deposit funds for liquidity provision on the destination chain and to withdraw funds (rage quit) from the ```DepositLocker``` prior to bridge.
   - Used on the destination chain to represent a depositor's position, execute the destination campaign's deposit recipes, and withdrawals after an absolute locktime.

2. **[DepositLocker](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/core/DepositLocker.sol)**: Deployed on the source chain
   - Integrates with Royco's RecipeMarketHub to facilitate deposits and withdrawals.
   - Accepts deposits from depositors' Weiroll Wallets upon an offer being filled in any CCDM integrated market.
   - Allows for depositors to withdraw funds until deposits are bridged.
   - Relies on a verifying party (green lighter) to flag when funds for a specific market are ready to bridge based on the state of the ```DepositExecutor``` on the destination chain.
      - The green lighter will maintain a wholestic view of the entire system (locker and executor) to deem whether or not the funds for a given market are safe to bridge based on the destination campaign's recipes in addition to the causal effects of executing them.
   - Bridges funds and destination execution parameters to the destination chain via LayerZero V2.

3. **[DepositExecutor](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/core/DepositExecutor.sol)**: Deployed on the destination chain
   - Maintains a mapping of source Royco markets to their corresponding deposit campaign's owner, locktime, and recipes on the destination chain.
   - Lets the owner of the deposit campaign set its locktime (once) and the campaign's deposit and withdrawal recipes.
   - Receives the bridged funds and parameters via LayerZero and atomically creates Weiroll Wallets for all bridged depositors
   - Allows the owner of the deposit campaign to execute deposit scripts for wallets associated with their campaign.
   - Allows the depositor to execute the withdrawal recipe after the locktime has passed
   - Relies on a verifying party (script verifier) to validate that the deposit and withdrawal recipe's work as expected.
      - The campaign's owner cannot execute the deposit recipes for their depositors' Weiroll Wallets until newly added scripts have been verified.

## CCDM Flow
1. IP creates a Royco Recipe Market on the source chain.
   - The market's deposit and withdrawal recipes will call the ```deposit()``` and ```withdraw()``` functions on the ```DepositLocker``` respectively.
2. IPs and APs place and negotiate the terms of offers through Royco.
3. Upon an offer being filled: 
   - The Recipe Market Hub creates a fresh Weiroll Wallet owned by the AP.
   - The Recipe Market Hub automatically executes the market's deposit recipe through the wallet, depositing the liqudiity into the ```DepositLocker```.
   - The deposit is withdrawable by the AP any time prior to their funds being bridged.
5. Once green light is given for a market, its funds can be bridged to the destination chain from the ```DepositLocker```.
6. The ```DepositExecutor``` receives bridged funds belonging to a source market and creates Weiroll Wallets for each depositor as specified by the bridged execution parameters and the destination campaign's parameters.
7. The destination deposit recipe is executed (if verified) by the campaign's owner for the Weiroll Wallets associated with their campaign on the destination chain.
8. Users can withdraw funds through the ```DepositExecutor``` after the campaign's locktime has elapsed.