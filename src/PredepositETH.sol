// SPDX-License-Identifier: UNLICENSED

import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";

pragma solidity ^0.8.19;

contract PredepositETH {

    mapping(uint256 => ERC20) public marketIDToDepositToken;

    mapping(uint256 => mapping(address => uint256)) public targetMarketIDToUserToDepositAmount;

    // address[] public depositTokens;
    // mapping(address => address) public isDepositToken;

    constructor() {
        // Constructor logic here
    }


    function deposit(uint256 targetMarketID, address user, uint256 amount) external {
        targetMarketIDToUserToDepositAmount[targetMarketID][user] += amount;
        marketIDToDepositToken[targetMarketID].transferFrom(msg.sender, address(this), amount);
    }

    function bridge(uint256 targetMarketID, address user) external payable {
        uint256 amount = targetMarketIDToUserToDepositAmount[targetMarketID][user];

        // generated below
        targetMarketIDToUserToDepositAmount[targetMarketID][user] = 0;
        // Prepare the transaction parameters
        (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) =
            integration.prepareTakeTaxi(stargate, targetMarketID, amount, user); // TODO: errors in params

        // Ensure enough ETH is sent to cover the transaction
        require(msg.value >= valueToSend, "Insufficient ETH sent");

        // Approve the Stargate contract to spend tokens
        ERC20 token = marketIDToDepositToken[targetMarketID];
        token.approve(stargate, amount);

        // Execute the omnichain transaction
        IStargate(stargate).sendToken{ value: valueToSend }(sendParam, messagingFee, user);

        // Refund any excess ETH
        if (msg.value > valueToSend) {
            payable(msg.sender).transfer(msg.value - valueToSend);
        }
    }
}

