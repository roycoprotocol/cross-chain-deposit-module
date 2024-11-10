//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IWETH
 * @dev Interface for a wrapped native asset token (wETH)
 */
interface IWETH {
    /// @notice Wraps the native assets sent (msg.value) and adds them to the msg.sender's balance
    function deposit() external payable;

    /// @notice Unwraps the specified native assets and remits them to the msg.sender
    function withdraw(uint256) external;
}
