//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IWETH {
    /// @notice Wraps the native assets sent (msg.value) and adds them to the msg.sender's balance
    function deposit() external payable;

    /// @notice Unwraps the specified native assets and remits them to the msg.sender
    function withdraw(uint256) external;
}
