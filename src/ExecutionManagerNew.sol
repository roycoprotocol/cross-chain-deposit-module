// SPDX-License-Identifier: UNLICENSED

import {Owned} from "solmate/auth/Owned.sol";
import {WeirollWallet} from "./WeirollWallet.sol";

pragma solidity ^0.8.19;

contract ExecutionManagerNew is Owned {
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;
    
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

    address public immutable WEIROLL_WALLET_IMPLEMENTATION;

    mapping(uint256 => address) internal campaignIDToOwner;
    mapping(uint256 => Campaign) internal campaignIDToCampaign;

    error OnlyOwnerOfCampaign();
    error ArrayLengthMismatch();

    modifier onlyOwnerOfCampaign(uint256 campaignID) {
        if (msg.sender != campaignIDToOwner[campaignID])
            revert OnlyOwnerOfCampaign();
        _;
    }

    // modifier to check if the weiroll wallet is unlocked
    modifier weirollIsUnlocked(address weirollWallet) {
        if (WeirollWallet(payable(weirollWallet)).lockedUntil() > block.timestamp) {
            revert WalletLocked();
        }
        _;
    }

    // modifier to check if msg.sender is owner of a weirollWallet
    modifier isWeirollOwner(address weirollWallet) {
        if (WeirollWallet(payable(weirollWallet)).owner() != msg.sender) {
            revert NotOwner();
        }
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
            address user = users[i];
            uint256 amount = amounts[i];
            uint256 expiry = expiries[i];

            // Make a weiroll wallet for the user
            WeirollWallet wallet = WEIROLL_WALLET_IMPLEMENTATION.clone(abi.encodePacked(user, address(this),amount, false, expiry, campaignID));
            campaign.inputToken.safeTransfer(address(wallet), amount);
            wallet.executeWeiroll(campaign.depositRecipe.weirollCommands, campaign.depositRecipe.weirollState);
        }
    }

    /// @notice Execute the withdrawal script in the weiroll wallet
    function executeWithdrawalScript(address weirollWallet) external isWeirollOwner(weirollWallet) weirollIsUnlocked(weirollWallet) {
        _executeWithdrawalScript(weirollWallet);
    }
}
