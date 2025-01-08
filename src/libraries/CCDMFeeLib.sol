// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title CCDMFeeLib
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A library for estimating the gas consumed by the Deposit Executor's lzCompose function.
library CCDMFeeLib {
    /// @notice Gas used by lzCompose in the Deposit Executor for a merkle bridge.
    /// @dev Padded by a small amount to ensure that lzCompose does not revert.
    uint128 internal constant GAS_FOR_MERKLE_BRIDGE = 245_000;

    /// @notice Gas used by lzCompose in the Deposit Executor for bridging a single depositor.
    /// @dev Padded by a small amount to ensure that lzCompose does not revert.
    uint256 internal constant BASE_GAS_FOR_INDIVIDUAL_DEPOSITORS_BRIDGE = 245_000;

    /// @notice Gas used by lzCompose in the Deposit Executor for each marginal depositor after the first.
    /// @dev Padded by a small amount to ensure that lzCompose does not revert.
    uint256 internal constant GAS_PER_ADDITIONAL_DEPOSITOR = 23_800;

    /// @notice Calculates the total gas required for the destination's lzCompose call for a given number of bridged depositors.
    /// @param _numDepositors The number of depositors for that will be bridged in the CCDM transaction.
    function estimateDestinationGasLimit(uint256 _numDepositors) internal pure returns (uint128) {
        // The total gas cost grows linearly from the base gas with the number of additional depositors.
        return uint128(BASE_GAS_FOR_INDIVIDUAL_DEPOSITORS_BRIDGE + (GAS_PER_ADDITIONAL_DEPOSITOR * (_numDepositors - 1)));
    }
}
