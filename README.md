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
4. Once green light is given for a market, its funds can be bridged to the destination chain from the ```DepositLocker```.
5. The ```DepositExecutor``` receives bridged funds belonging to a source market and creates Weiroll Wallets for each depositor as specified by the bridged execution parameters and the destination campaign's parameters.
6. The destination deposit recipe is executed (if verified) by the campaign's owner for the Weiroll Wallets associated with their campaign on the destination chain.
7. Users can withdraw funds through the ```DepositExecutor``` after the campaign's locktime has elapsed.

## CCDM Token Support
As of today, CCDM supports 2 types of input tokens for Royco Markets: Single and LP (only UNIV2 for now). As the name suggests, single tokens will result in a single LZ bridging transaction invoked by the ```DepositLocker```, resulting in the ```DepositExecutor``` creating Weiroll Wallets for all bridged depositors with their respective deposit amounts. Dual and LP tokens will result in two consecutive LZ bridging transactions, one for each constituent/pool token, invoked by the ```DepositLocker```. Each bridge transaction will contain the same CCDM nonce, notifying the ```DepositExecutor``` to create Weiroll Wallets and fund them with the received constiutuent upon receving the first bridge, and simply transfer the second constituents to the previously created Weiroll Wallets upon receiving the second bridge.

1. **Single Tokens**: Any ERC20 token which represents a single asset (wETH, wBTC, LINK, etc.).
   - Bridging Function: ```bridgeSingleTokens()```
3. **Dual Tokens**: An ERC20 token which is backed by a static ratio of 2 constiuent ERC20 tokens.
   - DualTokens are a CCDM specific standard and are meant to be used for bridging relatively stable pairs of tokens.
   - DualTokens have 0 decimals, meaning they can only be expressed as whole units.
   - DualTokens should be created through the ```DualTokenFactory``` contract which is deployed in the constructor of the ```DepositLocker```.
   - Bridging Function: ```bridgeDualTokens()```
3. **[Uniswap V2 LP Tokens](https://docs.uniswap.org/contracts/v2/reference/smart-contracts/pair)**
   - They are meant to be used when bridging unstable token pairs. Since they are self-rebalancing, they maintain the correct ratio of each asset based on their market prices. 
   - When the incentivized action on the destination chain is LPing into an unstable pool, LP tokens will reflect accurate ratios for the target pool up until the bridge.
   - Since bridging LP tokens requires redeeming them for their underlying pool tokens, impermanent loss becomes permanent. Due to this condition, only the owner of an LP market can bridge LP tokens in addition to specifying the minimum amounts of each pool token received on redeem.
   - Bridging Function: ```bridgeLpTokens()```