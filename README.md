# Cross-Chain Deposit Module (CCDM) [![Tests](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml/badge.svg)](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml)

The Cross-Chain Deposit Module (CCDM) is a sophisticated system designed to facilitate cross-chain deposit campaigns. Protocols can incentivize users to commit liquidity on any source chain towards agreed upon actions (supplying, LPing, swapping, etc.) on a destination chain. CCDM consists of two main components: the **Deposit Locker** on the source chain and the **Deposit Executor** on the destination chain.

## CCDM Technical Overview

CCDM allows users to deposit funds on one chain (source) and have those funds bridged and utilized on another chain (destination) according to campaign specific action logic. It leverages [LayerZero](https://docs.layerzero.network/v2) V2 for cross-chain communication and token bridging. The system supports all tokens that can be bridged using LayerZero V2's [OFT](https://docs.layerzero.network/v2/home/token-standards/oft-standard) standard.

### Key Components

1. **[RecipeMarketHub](https://github.com/roycoprotocol/royco/blob/main/src/RecipeMarketHub.sol)**: A hub for all recipe market interactions between APs and IPs on Royco
   - Permissionless market creation and offer creation, negotiation, and filling
   - Atomic Weiroll Wallet creation and execution of deposit recipes upon an offer being filled.
   - Allows APs to execute withdrawal recipes to reclaim their funds.

1. **[WeirollWallet](https://github.com/roycoprotocol/royco/blob/main/src/WeirollWallet.sol)**: Smart contract wallets (owned by depositors) used to execute recipes
   - Used on the source chain to deposit funds for liquidity provision on the destination chain and to withdraw funds (rage quit) from the ```DepositLocker``` prior to bridge.
   - Used on the destination chain to hold multiple depositors' positions from the same market, execute the destination campaign's deposit recipes, and hold the receipt tokens for withdrawal after an unlock timestamp.

2. **[DepositLocker](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/core/DepositLocker.sol)**: Deployed on the source chain
   - Integrates with Royco's RecipeMarketHub to facilitate deposits and withdrawals.
   - Accepts deposits from depositors' Weiroll Wallets upon an offer being filled in any CCDM integrated market.
   - Allows for depositors to withdraw funds until deposits are bridged.
   - Relies on a verifying party (green lighter) to flag when funds for a specific market are ready to bridge based on the state of the ```DepositExecutor``` on the destination chain.
      - The green lighter will maintain a wholestic view of the entire system (locker and executor) to deem whether or not the funds for a given market are safe to bridge based on the destination campaign's input tokens, receipt token, and deposit recipe in addition to the causal effects of executing them.
      - After the green lighter gives the green light for a market, depositors have an additional 48 hours to "rage quit" from the campaign before they can be bridged.
   - Bridges funds and specific depositer data (addresses and deposit amounts) to the destination chain via LayerZero V2.
      - Each bridge transaction has a CCDM Nonce attached to it. Multiple LZ bridge transactions can have the same CCDM Nonce, ensuring that the tokens end up in the same Weiroll Wallet on the destination chain.

3. **[DepositExecutor](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/core/DepositExecutor.sol)**: Deployed on the destination chain
   - Maintains a mapping of source chain Royco markets to their corresponding deposit campaign's owner, unlock timestamp, input tokens, receipt token, and deposit recipe on the destination chain.
   - Relies on a verifying party (campaign verifier) to validate that the deposit recipe will work as expected given the currently set input tokens, receipt token, and deposit recipe.
   - Lets the owner of the deposit campaign set its unlock timestamp (once) and the campaign's input tokens, receipt token, and deposit recipe.
      - The input tokens and receipt token are considered immutable after the first deposit recipe successfully executes for a campaign.
      - Deposit recipes are eternally mutable, but changing them unverfies the campaign.
   - Receives the bridged funds and depositor data via LayerZero and atomically creates one Weiroll Wallet per CCDM Nonce.
   - Allows owners of deposit campaigns to execute deposit recipes for wallets associated with their campaign.
   - Allows depositors to withdraw their prorated share of receipt tokens (if deposit recipe has executed) or their original deposit (if the deposit recipe hasn't executed) after the unlock timestamp has passed.

## CCDM Flow
1. IP creates a Royco Recipe Market on the source chain.
   - The market's deposit recipe will approve the ```DepositLocker``` to spend the amount of tokens deposited (fill amount) and then call the ```deposit()``` functions on the ```DepositLocker```.
   -  The market's withdrawal recipe will call ```withdraw()``` on the ```DepositLocker```.
2. IPs and APs place and negotiate the terms of offers through Royco.
3. Upon an offer being filled: 
   - The Recipe Market Hub creates a fresh Weiroll Wallet owned by the AP.
   - The Recipe Market Hub automatically executes the market's deposit recipe through the wallet, depositing the liqudiity into the ```DepositLocker```.
   - The deposit is withdrawable by the AP any time prior to their funds being bridged.
4. Once green light is given for a market, its funds can be bridged to the destination chain from the ```DepositLocker``` after.
5. The ```DepositExecutor``` receives bridged funds belonging to a source market and creates a Weiroll Wallet for the CCDM nonce associated with the bridge transaction if it hasn't aleady. It also stores granular accounting for each bridged depositor to facilitate prorated withdrawals.
6. The destination deposit recipe is executed (if verified) by the campaign's owner for the Weiroll Wallets associated with their campaign on the destination chain.
7. Users can withdraw funds through the ```DepositExecutor``` after the campaign's unlock timestamp has passed.

## CCDM Token Support
As of today, CCDM supports 2 types of input tokens for Royco Markets: Single and LP (only UNIV2 for now). As the name suggests, bridging single tokens will result in a single LZ bridging transaction invoked by the ```DepositLocker```. Birdging LP tokens, on the other hand, will result in two consecutive LZ bridging transactions, one for each constituent token in the pool. Each LZ bridge transaction will contain the same CCDM Nonce, notifying the ```DepositExecutor``` to send both constiutuents to the same Weiroll Wallet.

1. **Single Tokens**: Any ERC20 token which represents a single asset (wETH, wBTC, LINK, etc.).
   - Bridging Function: ```bridgeSingleTokens()```
2. **[Uniswap V2 LP Tokens](https://docs.uniswap.org/contracts/v2/reference/smart-contracts/pair)**
   - Meant to be used when the incentivized action on the destination chain is LPing into a liquidity pool.
   - Since LP tokens are continuously rebalancing, they maintain the correct ratio for the constituents based on the market price. 
   - Since bridging LP tokens requires redeeming them for their underlying pool tokens, impermanent loss becomes permanent. Due to this condition, only the owner of an LP market can bridge LP tokens in addition to specifying the minimum amounts of each pool token received on redeem.
   - Bridging Function: ```bridgeLpTokens()```