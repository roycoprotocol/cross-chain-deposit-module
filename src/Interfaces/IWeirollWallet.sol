// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title IWeirollWallet
/// @author Royco
interface IWeirollWallet {
    /// @notice The address of the order creator (owner)
    function owner() external pure returns (address);

    /// @notice The address of the recipeKernel exchange contract
    function recipeKernel() external pure returns (address);

    /// @notice The amount of tokens deposited into this wallet from the recipeKernel
    function amount() external pure returns (uint256);

    /// @notice The timestamp after which the wallet may be interacted with
    function lockedUntil() external pure returns (uint256);

    /// @notice Returns the marketId associated with this weiroll wallet
    function marketId() external pure returns (uint256);
}
