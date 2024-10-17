// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the PredepositLocker contract and its dependencies
import { PredepositLocker, RecipeMarketHubBase, ERC20 } from "src/PredepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, RewardStyle, Points } from "test/utils/RecipeMarketHubTestBase.sol";
import { IStargate } from "src/interfaces/IStargate.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

// Test Bridging Deposits on ETH Mainnet fork
contract TestBridgeDeposits_PredepositLocker is RecipeMarketHubTestBase {
    using FixedPointMathLib for uint256;

    address IP_ADDRESS;
    address AP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    address USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address USDT_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    uint256 mainnetFork;

    function setUp() external {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
    }

    function test_BridgeDeposits(uint256 offerAmount, uint256 numDepositors) external {
        numDepositors = bound(numDepositors, 1, 20);
        offerAmount = bound(offerAmount, 1e18, type(uint64).max);

        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        AP_ADDRESS = BOB_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory predepositTokens = new ERC20[](2);
        IStargate[] memory stargates = new IStargate[](2);

        predepositTokens[0] = ERC20(USDC_ADDRESS); // USDC on ETH Mainnet
        predepositTokens[1] = ERC20(USDT_ADDRESS); // USDT on ETH Mainnet

        stargates[0] = IStargate(0xc026395860Db2d07ee33e05fE50ed7bD583189C7); // Stargate USDC Pool on ETH Mainnet
        stargates[1] = IStargate(0x933597a323Eb81cAe705C5bC29985172fd5A3973); // Stargate USDT Pool on ETH Mainnet

        deal(USDC_ADDRESS, AP_ADDRESS, offerAmount);
        deal(USDT_ADDRESS, AP_ADDRESS, offerAmount);

        // Locker for bridging to IOTA (Stargate Hydra on destination chain)
        PredepositLocker predepositLocker = new PredepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), predepositTokens, stargates, recipeMarketHub);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(PredepositLocker.deposit.selector, address(walletHelper), USDC_ADDRESS, address(predepositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(PredepositLocker.withdraw.selector, address(predepositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        bytes32 marketHash = recipeMarketHub.createMarket(USDC_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), 0);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        vm.startPrank(AP_ADDRESS);
        ERC20(USDC_ADDRESS).approve(address(recipeMarketHub), offerAmount);
        vm.stopPrank();

        address payable[] memory depositorWallets = new address payable[](numDepositors);
        for (uint256 i = 0; i < numDepositors; i++) {
            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }

            // Record the logs to capture Transfer events to get Weiroll wallet address
            vm.recordLogs();
            // AP Fills the offer (no funding vault)
            vm.startPrank(AP_ADDRESS);
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();

            // Extract the Weiroll wallet address (the 'to' address from the Transfer event - third event in logs)
            address payable weirollWallet = payable(address(uint160(uint256(vm.getRecordedLogs()[0].topics[2]))));

            depositorWallets[i] = weirollWallet;
        }

        vm.startPrank(OWNER_ADDRESS);
        predepositLocker.setMulitsig(marketHash, MULTISIG_ADDRESS);
        vm.stopPrank();

        vm.startPrank(MULTISIG_ADDRESS);
        predepositLocker.setGreenLight(marketHash, true);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, USDC_ADDRESS);
        emit ERC20.Transfer(address(predepositLocker), address(predepositLocker.tokenToStargate(ERC20(USDC_ADDRESS))), offerAmount);

        vm.startPrank(IP_ADDRESS);
        predepositLocker.bridge{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
        vm.stopPrank();
    }
}
