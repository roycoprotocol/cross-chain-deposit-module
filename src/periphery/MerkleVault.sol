// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { DepositExecutor } from "../core/DepositExecutor.sol";
import { MerkleProof } from "../../lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title MerkleVault
 * @notice A contract that coordinates deposits into a market, optionally using a Merkle proof to validate deposits,
 *         and manages halting/unhalting new deposits. Inherits from Ownable2Step and ReentrancyGuardTransient.
 * @dev
 *  - `Ownable2Step` enables a two-step ownership transfer, improving security around ownership changes.
 *  - `ReentrancyGuardTransient` protects external calls from reentrancy attacks in transient storage.
 *  - `SafeTransferLib` is used for safe ERC20 token transfers.
 */
contract MerkleVault is Ownable2Step, ReentrancyGuardTransient {
    /*//////////////////////////////////////////////////////////////
                             Shared State
    //////////////////////////////////////////////////////////////*/

    /// @notice The unique hash that identifies the market associated with this vault.
    bytes32 public immutable marketHash;

    /*//////////////////////////////////////////////////////////////
                             Source State
    //////////////////////////////////////////////////////////////*/

    /// @notice Whether or not deposits to this vault are currently halted.
    bool public depositsHalted;

    /*//////////////////////////////////////////////////////////////
                             Destination State
    //////////////////////////////////////////////////////////////*/

    /// @notice An instance of DepositExecutor on destination.
    DepositExecutor depositExecutor;
    /// @notice The Merkle root used to validate participants or deposits in some markets (optional usage).
    bytes32 merkleRoot;

    /**
     * @notice Thrown when an action cannot proceed because deposits are halted.
     */
    error DepositsHalted();

    /**
     * @notice Initializes the vault with a specific owner and market hash.
     * @dev The `marketHash` is immutable, ensuring it cannot be changed after deployment.
     * @param _owner The address to be set as the owner of this vault.
     * @param _marketHash The unique identifier (hash) of the market to which this vault corresponds.
     */
    constructor(address _owner, bytes32 _marketHash) Ownable(_owner) {
        marketHash = _marketHash;
    }

    /**
     * @notice Sets the DepositExecutor and the Merkle root required to validate withdrawals.
     * @dev
     *  - Only callable by the current owner.
     *  - Allows the owner to configure or re-configure this vault after deployment.
     * @param _depositExecutor The contract responsible for executing deposit logic on another chain or context.
     * @param _merkleRoot The Merkle root to be used for proof validation in deposit operations.
     */
    function initializeDestVault(DepositExecutor _depositExecutor, bytes32 _merkleRoot) external onlyOwner {
        depositExecutor = _depositExecutor;
        merkleRoot = _merkleRoot;
    }

    /**
     * @notice Halts all further deposits to this vault.
     * @dev Only callable by the owner. Halting is IMMUTABLE.
     */
    function haltDeposits() external onlyOwner {
        depositsHalted = true;
    }

    /**
     * @notice Checks if the vault is halted for deposits; reverts if it is.
     * @dev Must be called on the source market's deposit recipe before calling depositFor on the Deposit Locker.
     */
    function checkDepositsHalted() external view {
        require(!depositsHalted, DepositsHalted());
    }
}
