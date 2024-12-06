// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { ClonesWithImmutableArgs } from "@clones-with-immutable-args/ClonesWithImmutableArgs.sol";

/// @title WeirollWalletFactory
/// @notice This factory creates mock Weiroll Wallet instances created by the CCDM Deposit Executor.
/// @dev Uses ClonesWithImmutableArgs to deploy minimal proxy clones of a single WeirollWallet implementation.
///      The deployed wallets can be customized with immutable arguments passed at creation time.
contract WeirollWalletFactory {
    using ClonesWithImmutableArgs for address;

    /// @notice The address of the WeirollWallet implementation contract used as the template for clones.
    /// @dev This contract never changes, ensuring all clones share the same base logic.
    address public immutable WEIROLL_WALLET_IMPLEMENTATION;

    /// @notice Deploys the WeirollWallet implementation once during contract construction.
    /// @dev The WeirollWallet at WEIROLL_WALLET_IMPLEMENTATION will be referenced to create all future clones.
    constructor() {
        WEIROLL_WALLET_IMPLEMENTATION = address(new WeirollWallet());
    }

    /// @notice Creates a new WeirollWallet clone with the specified parameters.
    /// @dev This function encodes and passes immutable arguments to the Weiroll Wallet clone.
    /// @dev The `amount` arg is hard-coded to zero because CCDM Weiroll Wallets created on the destination might hold multiple tokens.
    /// @dev The `forfeitable` arg is hard-coded to false because CCDM Weiroll Wallets created on the destination aren't forfeitable.
    /// @dev The `marketHash` arg is hard-coded to bytes(0) because this value isn't intended for use in recipe execution.
    /// @param _depositExecutor The address designated as the Deposit Executor (entrypoint for executing recipes pre- and post-unlock).
    /// @param _unlockTimestamp The absolute timestamp after which the owner can execute calls.
    /// @return weirollWallet The address of the newly deployed WeirollWallet clone.
    function createDepositExecutorWeirollWallet(address _depositExecutor, uint256 _unlockTimestamp) external returns (address payable weirollWallet) {
        weirollWallet = payable(
            WEIROLL_WALLET_IMPLEMENTATION.clone(
                abi.encodePacked(
                    address(0), // Wallet owner will be zero address so no single party can siphon depositor funds after lock timestamp has passed.
                    _depositExecutor, // Entrypoint for recipe execution (mock CCDM Deposit Executor).
                    uint256(0), // Hardcoded amount; always 0.
                    _unlockTimestamp, // Absolute timestamp at which deposit are unlocked for withdrawals.
                    false, // Non-forfeitable wallet, as deposits are on the destination chain.
                    bytes32(0) // Hardcoded source market hash for a campaign.
                )
            )
        );
    }
}
