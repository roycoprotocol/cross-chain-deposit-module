// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Import the DepositExecutor contract and its dependencies
import { RecipeMarketHub, RewardStyle } from "@royco/src/RecipeMarketHub.sol";
import { WeirollWalletHelper } from "test/utils/WeirollWalletHelper.sol";
import "src/core/DepositLocker.sol";

contract SourceBridgeScript is Script {
    address constant weirollHelperAddress = 0xf8E66EaC95D27DD30A756ee1A2D2D96D392b61CB;
    address payable constant depositLockerAddress = payable(0x844F6B31f7D1240134B3d63ffC2b6f1c7F2612b6);
    address constant usdc_address = 0x488327236B65C61A6c083e8d811a4E0D3d1D4268; // Stargate USDC on OP Sepolia
    uint256 constant numDepositors = 150;
    uint256 constant offerSize = 1e9 * numDepositors;

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

        // Create Market

        // RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
        //     _buildDepositRecipe(DepositLocker.deposit.selector, weirollHelperAddress, usdc_address, depositLockerAddress);
        // RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, depositLockerAddress);
        // bytes32 marketHash = recipeMarketHub.createMarket(usdc_address, 8 weeks, 0.001e18, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        bytes32 marketHash = bytes32(0xcd520b87754ed96438e199c82c143337c3024af70d0e26ea04f614377e687de8);

        // Approve the market hub to spend usdc
        ERC20(usdc_address).approve(address(recipeMarketHub), type(uint256).max);

        address[] memory incentivesOffered = new address[](1);
        incentivesOffered[0] = usdc_address;
        uint256[] memory incentiveAmountsPaid = new uint256[](1);
        incentiveAmountsPaid[0] = 100e6;
        bytes32 offerHash = recipeMarketHub.createIPOffer(marketHash, offerSize, block.timestamp + 2 weeks, incentivesOffered, incentiveAmountsPaid);

        bytes32[] memory ipOfferHashes = new bytes32[](1);
        ipOfferHashes[0] = offerHash;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = offerSize / numDepositors;

        address[] memory depositorWallets = new address[](1);
        depositorWallets[0] = deployer;
        for (uint256 i; i < numDepositors; ++i) {
            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), deployer);
        }

        DepositLocker depositLocker = DepositLocker(depositLockerAddress);

        depositLocker.setGreenLighter(deployer);

        depositLocker.turnGreenLightOn(marketHash);

        depositLocker.bridgeSingleTokens{ value: 1 ether }(marketHash, 25_000_000, depositorWallets);

        // Stop broadcasting transactions
        vm.stopBroadcast();
    }

    // Get fill amount using Weiroll Helper -> Approve fill amount -> Call Deposit
    function _buildDepositRecipe(
        bytes4 _depositSelector,
        address _helper,
        address _tokenAddress,
        address _depositLockerAddress
    )
        internal
        pure
        returns (RecipeMarketHubBase.Recipe memory)
    {
        bytes32[] memory commands = new bytes32[](3);
        bytes[] memory state = new bytes[](2);

        state[0] = abi.encode(_depositLockerAddress);

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

        // APPROVE Deposit Locker to spend tokens

        // CALL
        f = uint8(0x01);

        // Input list: Args at state index 0 (address) and args at state index 1 (fill amount)
        inputData = hex"0001ffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = 0xff;

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[1] = (bytes32(abi.encodePacked(ERC20.approve.selector, f, inputData, o, _tokenAddress)));

        // CALL DEPOSIT() in Deposit Locker
        f = uint8(0x01);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = uint8(0xff);

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[2] = (bytes32(abi.encodePacked(_depositSelector, f, inputData, o, _depositLockerAddress)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }

    function _buildWithdrawalRecipe(bytes4 _withdrawalSelector, address _depositLockerAddress) internal pure returns (RecipeMarketHubBase.Recipe memory) {
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
        commands[0] = (bytes32(abi.encodePacked(_withdrawalSelector, f, inputData, o, _depositLockerAddress)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }
}
