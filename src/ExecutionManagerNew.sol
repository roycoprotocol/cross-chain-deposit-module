// SPDX-License-Identifier: UNLICENSED

import {Owned} from "solmate/auth/Owned.sol";

pragma solidity ^0.8.19;

contract ExecutionManagerNew is Owned {
    
    /// @custom:field weirollCommands The weiroll script that will be executed on an AP's weiroll wallet after receiving the inputToken
    /// @custom:field weirollState State of the weiroll VM, necessary for executing the weiroll script
    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    struct Campaign {
        address inputToken;
        Recipe depositRecipe;
        Recipe withdrawalRecipe;
    }

    mapping(uint256 => address) internal campaignIDToOwner;
    mapping(uint256 => Campaign) internal campaignIDToCampaign;

    error OnlyOwnerOfCampaign();
    error ArrayLengthMismatch();

    modifier onlyOwnerOfCampaign(uint256 campaignID) {
        if (msg.sender != campaignIDToOwner[campaignID])
            revert OnlyOwnerOfCampaign();
        _;
    }

    constructor(address _owner) Owned(_owner) {}

    function setCampaignOwner(uint256 campaignID, address newOwner) external onlyOwnerOfCampaign(campaignID) {
        campaignIDToOwner[campaignID] = newOwner;
    }

    function setDepositRecipe(uint256 campaignID, bytes32[] memory weirollCommands, bytes[] memory weirollState) external onlyOwnerOfCampaign(campaignID) {
        campaignIDToCampaign[campaignID].depositRecipe = Recipe(weirollCommands, weirollState);
    }

    function setWithdrawalRecipe(uint256 campaignID, bytes32[] memory weirollCommands, bytes[] memory weirollState) external onlyOwnerOfCampaign(campaignID) {
        campaignIDToCampaign[campaignID].withdrawalRecipe = Recipe(weirollCommands, weirollState);
    }

    function createCampaign(uint256 campaignID, address owner, address inputToken) external onlyOwner {
        campaignIDToOwner[campaignID] = owner;
        campaignIDToCampaign[campaignID].inputToken = inputToken;
    }

    function receivePredeposits(uint256 campaignID, address[] memory users, uint256[] memory amounts, uint256[] memory expiries) external {
        if(users.length != amounts.length)
            revert ArrayLengthMismatch();

        Campaign memory campaign = campaignIDToCampaign[campaignID];
        
        uint256 len = users.length;
        for (uint256 i = 0; i < len; i++) {
            // Make a weiroll wallet for the user
        }
    }
}
