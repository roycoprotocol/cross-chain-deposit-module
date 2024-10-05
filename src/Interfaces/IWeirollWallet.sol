// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

interface IWeirollWallet {
    function executeWeiroll(bytes32[] calldata commands, bytes[] calldata state) external payable returns (bytes[] memory);
    function lockedUntil() external pure returns (uint256);
}