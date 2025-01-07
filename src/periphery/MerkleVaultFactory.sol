// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { MerkleVault } from "./MerkleVault.sol";
import { Ownable2Step, Ownable } from "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/**
 * @title MerkleVaultFactory
 * @author Shivaansh Kapoor, Jack Corddry
 * @notice A factory contract responsible for deploying new MerkleVault instances for different markets.
 * @dev
 *  - Uses CREATE2 (with a fixed salt) to deterministically deploy MerkleVault contracts.
 *  - Will deploy vaults with the same vault owner and market hash to the same addresses on the source and destination chain.
 */
contract MerkleVaultFactory is Ownable2Step {
    /// @notice A constant salt used in CREATE2 for deterministic vault deployments.
    bytes32 public constant MERKLE_VAULT_DEPLOYMENT_SALT = keccak256(abi.encodePacked("BOYCO"));

    /// @notice Maps each market hash to its deployed MerkleVault address.
    mapping(bytes32 => address) public marketHashToMerkleVault;

    /**
     * @notice Emitted when a new MerkleVault is deployed.
     * @param marketHash The unique hash representing the market associated with the MerkleVault.
     * @param vaultOwner The address designated as the owner of the newly deployed vault.
     * @param merkleVault The address of the newly deployed MerkleVault.
     */
    event MerkleVaultDeployed(bytes32 indexed marketHash, address indexed vaultOwner, address indexed merkleVault);

    /// @notice Thrown when attempting to deploy a MerkleVault for a market hash that already has one.
    error InvalidMerkleVaultDeployment();

    /**
     * @notice Initializes the factory contract and sets the initial owner.
     * @dev This MUST be same on source and destination to ensure the factory deploys vaults to the same address on source and destination.
     * @param _owner The address to be set as the owner of the factory.
     */
    constructor(address _owner) Ownable(_owner) { }

    /**
     * @notice Deploys a new MerkleVault for a given market, using CREATE2, and registers it in the mapping.
     * @dev
     *  - Only callable by the contract owner (restricted by `onlyOwner`).
     *  - Uses a fixed salt for CREATE2 to ensure that vaults with the same market hash and vault owner deploy at the same address on source and destination.
     * @param _marketHash The hash representing the market the vault will be deployed for.
     * @param _vaultOwner The address to be assigned as the owner of the newly deployed MerkleVault. This MUST be same on source and destination for the
     * corresponding market to deploy vaults to the same addresses on the source and destination chain.
     * @return merkleVault The address of the newly created MerkleVault.
     */
    function deployMerkleVault(bytes32 _marketHash, address _vaultOwner) external onlyOwner returns (address merkleVault) {
        // Check if a MerkleVault is already deployed for this market and ensure a valid _vaultOwner
        merkleVault = marketHashToMerkleVault[_marketHash];
        require(address(merkleVault) == address(0) && _vaultOwner != address(0), InvalidMerkleVaultDeployment());

        // Deploy the MerkleVault with CREATE2
        merkleVault = address(new MerkleVault{ salt: MERKLE_VAULT_DEPLOYMENT_SALT }(_vaultOwner, _marketHash));

        // Store the Merkle Vault for the specified market and emit the event
        marketHashToMerkleVault[_marketHash] = merkleVault;
        emit MerkleVaultDeployed(_marketHash, _vaultOwner, merkleVault);
    }
}
