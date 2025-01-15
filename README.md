# Cross-Chain Deposit Module (CCDM) [![Tests](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml/badge.svg)](https://github.com/roycoprotocol/cross-chain-deposit-module/actions/workflows/test.yml)

The **Cross-Chain Deposit Module (CCDM)** is a sophisticated system built on **[Royco](https://github.com/roycoprotocol/royco)**, designed to facilitate cross-chain liquidity acquisition campaigns. IPs can incentivize APs to commit liquidity on a source chain towards agreed-upon actions (supplying, LPing, swapping, etc.) on a destination chain. **Royco** provides efficient price discovery for protocols trying to acquire liquidity for a desired timeframe. CCDM handles safely transporting this liquidity to the intended protocol in a trust minimized manner. A single **CCDM** instance can facilitate campaigns from a single source chain to a single destination chain.

CCDM consists of two core components: the **Deposit Locker** on the source chain and the **Deposit Executor** on the destination chain. All incentive negotiation and liquidity provision is powered by **Royco Recipe IAMs** that live on the source chain. Visit the following documentation for a comprehensive explanation of how each CCDM component operates:

* **[CCDM Enabled Recipe IAMs](https://docs.royco.org/ccdm/ccdm-overview/ccdm-recipe-iams)** - *Source Chain*
* **[Deposit Locker](https://docs.royco.org/ccdm/ccdm-overview/deposit-locker)** - *Source Chain*
* **[Deposit Executor](https://docs.royco.org/ccdm/ccdm-overview/deposit-executor)** - *Destination Chain*


### Technical Components

1. **[RecipeMarketHub](https://github.com/roycoprotocol/royco/blob/main/src/RecipeMarketHub.sol)**: A hub for all Recipe IAM interactions between APs and IPs on Royco. Deployed on the source chain.
   - Permissionless market creation and offer creation, negotiation, and filling.
   - Atomic Weiroll Wallet creation and execution of deposit recipes upon an offer being filled.
   - Allows APs to execute withdrawal recipes to reclaim their funds.

1. **[WeirollWallet](https://github.com/roycoprotocol/royco/blob/main/src/WeirollWallet.sol)**: Lightweight smart contract wallets used to execute [Weiroll Scripts/Recipes](https://github.com/weiroll/weiroll)
   - Used on the source chain to deposit funds for liquidity provision on the destination chain and to withdraw funds (rage quit) from the ```DepositLocker``` prior to bridge.
   - Used on the destination chain to hold multiple depositors' positions from the same market, execute the destination campaign's deposit recipes, and hold the receipt tokens for depositors to withdraw after an unlock timestamp.

2. **[DepositLocker](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/core/DepositLocker.sol)**: Deployed on the source chain
   - Integrates with Royco's RecipeMarketHub to facilitate deposits and withdrawals.
   - Accepts deposits from depositors' Weiroll Wallets upon an offer being filled in any CCDM integrated market.
   - Allows for depositors to withdraw funds until deposits are bridged.
   - Relies on a verifying party (green lighter) to flag when funds for a specific market are ready to bridge based on the state of the ```DepositExecutor``` on the destination chain.
      - The green lighter will maintain a wholestic view of the entire system (locker and executor) to deem whether or not the funds for a given market are safe to bridge based on the destination campaign's deposit recipe in addition to the causal effects of executing them.
      - After the green lighter gives the green light for a market, a "rage quit" duration starts, allowing depositors to withdraw from the campaign before they are bridged.
   - Bridges funds and a payload containing depositor data to the destination chain via LayerZero V2.
      - Each bridge transaction has a CCDM Nonce attached to it. Multiple LZ bridge transactions can have the same CCDM Nonce (eg. bridging UNI V2 LP positions), ensuring that the tokens end up in the same Weiroll Wallet on the destination chain.

3. **[DepositExecutor](https://github.com/roycoprotocol/cross-chain-deposit-module/blob/main/src/core/DepositExecutor.sol)**: Deployed on the destination chain
   - Maintains a mapping of source chain Royco markets to their corresponding deposit campaign's owner, unlock timestamp, receipt token, and deposit recipe on the destination chain.
   - Relies on a verifying party (campaign verifier) to validate that the deposit recipe will work as expected given the currently set campaign parameters.
   - Lets the owner of the deposit campaign set its unlock timestamp, receipt token, and deposit recipe.
      - The unlock timestamp is immutable after it is set once.
      - The receipt token is mutable until the first deposit recipe successfully executes for a campaign, but changing it unverfies the campaign.
      - Deposit recipes are eternally mutable, but changing it unverfies the campaign.
   - Receives the bridged funds and depositor data via LayerZero V2 and atomically creates one Weiroll Wallet per CCDM Nonce and stores the depositor data.
      - The ```DepositExecutor``` holds the Weiroll Wallet's deposits until the campaign owner executes the deposit recipe.
   - Allows owners of deposit campaigns to execute deposit recipes for wallets associated with their campaign.
   - Allows depositors to withdraw their prorated share of receipt tokens (if the deposit recipe has executed) or their original deposit (if the deposit recipe hasn't executed) after the unlock timestamp has passed.
