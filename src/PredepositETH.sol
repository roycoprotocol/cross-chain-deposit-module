
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

contract PredepositETH {

    mapping(uint256 => address) public marketIDToDepositToken;

    mapping(uint256 => mapping(address => uint256)) public targetMarketIDToUserToDepositAmount;

    address[] public depositTokens;

    constructor() {
        // Constructor logic here
    }


    function deposit(uint256 targetMarketID, address user, uint256 amount) external {
        targetMarketIDToUserToDepositAmount[targetMarketID][user] += amount;
        
    }


    // Contract functions here
}

