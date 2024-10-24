// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Import the PredepositExecutor contract and its dependencies
import { RecipeMarketHub, RewardStyle } from "@royco/src/RecipeMarketHub.sol";
import { WeirollWalletHelper } from "test/utils/WeirollWalletHelper.sol";
import "src/PredepositLocker.sol";

contract PredepositExecutorDeployScript is Script {
    address constant weirollHelper = 0xf8E66EaC95D27DD30A756ee1A2D2D96D392b61CB;
    address constant predepositLocker = 0x844F6B31f7D1240134B3d63ffC2b6f1c7F2612b6;
    address constant usdc_address = 0x3253a335E7bFfB4790Aa4C25C4250d206E9b9773;  // Stargate USDC on OP Sepolia

    RecipeMarketHub recipeMarketHub;

    function setUp() public {
        // Recipe Market Hub on OP Sepolia
        recipeMarketHub = RecipeMarketHub(0x828223B512BF1892229FeC61C5c1376BDED3a285);
    }

    function run() public {
        // Fetch the deployer's private key from environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(PredepositLocker.deposit.selector, weirollHelper, usdc_address, predepositLocker);
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(PredepositLocker.withdraw.selector, predepositLocker);

        recipeMarketHub.createMarket(usdc_address, 8 weeks, 0.001e18, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }

    // Get fill amount using Weiroll Helper -> Approve fill amount -> Call Deposit
    function _buildDepositRecipe(
        bytes4 _depositSelector,
        address _helper,
        address _tokenAddress,
        address _predepositLocker
    )
        internal
        pure
        returns (RecipeMarketHubBase.Recipe memory)
    {
        bytes32[] memory commands = new bytes32[](3);
        bytes[] memory state = new bytes[](2);

        state[0] = abi.encode(_predepositLocker);

        // GET FILL AMOUNT

        // STATICCALL
        uint8 f = uint8(0x02);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        bytes6 inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 1 of the output array)
        // 0xff ignores the output if any
        uint8 o = 0x01;

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[0] = (bytes32(abi.encodePacked(WeirollWalletHelper.amount.selector, f, inputData, o, _helper)));

        // APPROVE Predeposit Locker to spend tokens

        // CALL
        f = uint8(0x01);

        // Input list: Args at state index 0 (address) and args at state index 1 (fill amount)
        inputData = hex"0001ffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = 0xff;

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[1] = (bytes32(abi.encodePacked(ERC20.approve.selector, f, inputData, o, _tokenAddress)));

        // CALL DEPOSIT() in Predeposit Locker
        f = uint8(0x01);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = uint8(0xff);

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[2] = (bytes32(abi.encodePacked(_depositSelector, f, inputData, o, _predepositLocker)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }

    function _buildWithdrawalRecipe(bytes4 _withdrawalSelector, address _predepositLocker) internal pure returns (RecipeMarketHubBase.Recipe memory) {
        bytes32[] memory commands = new bytes32[](1);
        bytes[] memory state = new bytes[](0);

        // Flags:
        // DELEGATECALL (calltype = 0x00)
        // CALL (calltype = 0x01)
        // STATICCALL (calltype = 0x02)
        // CALL with value (calltype = 0x03)
        uint8 f = uint8(0x01);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        bytes6 inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        uint8 o = uint8(0xff);

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[0] = (bytes32(abi.encodePacked(_withdrawalSelector, f, inputData, o, _predepositLocker)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }
}
