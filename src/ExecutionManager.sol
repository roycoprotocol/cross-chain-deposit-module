// SPDX-License-Identifier: UNLICENSED

import { Ownable2Step } from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

pragma solidity ^0.8.19;

contract ExecutionManager is Ownable2Step {

    /// @custom:field weirollCommands The weiroll script that will be executed on an AP's weiroll wallet after receiving the inputToken
    /// @custom:field weirollState State of the weiroll VM, necessary for executing the weiroll script
    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    bool greenLightGiven;

    Recipe public depositRecipe;
    Recipe public withdrawalRecipe;

    constructor() {
        greenLightGiven = false;
    }

    function giveGreenLight() external onlyOwner {
        // check that depositRecipe and withdrawalRecipe are set
        if (depositRecipe.weirollCommands.length == 0 || withdrawalRecipe.weirollCommands.length == 0) {
            revert("Deposit or withdrawal recipe not set");
        }
        greenLightGiven = true;
        //either bridge this to eth now or just handle all of this via msig & delete these
    }

    function setDepositRecipe(bytes32[] weirollCommands, bytes[] weirollState) external onlyOwner {
        depositRecipe = Recipe(weirollCommands, weirollState);
    }

    function setWithdrawalRecipe(bytes32[] weirollCommands, bytes[] weirollState) external onlyOwner {
        withdrawalRecipe = Recipe(weirollCommands, weirollState);
    }
    
    
}
