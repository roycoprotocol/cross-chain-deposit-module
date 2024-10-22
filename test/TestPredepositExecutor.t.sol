// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the PredepositLocker contract and its dependencies
import { PredepositLocker, RecipeMarketHubBase, ERC20 } from "src/PredepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, RewardStyle, Points } from "test/utils/RecipeMarketHubTestBase.sol";
import { IStargate } from "src/interfaces/IStargate.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";

// Test deploying deposits via weiroll recipes post bridge
contract Test_PredepositExecutor is RecipeMarketHubTestBase {
    using FixedPointMathLib for uint256;

    address IP_ADDRESS;
    address AP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");
    string POLYGON_RPC_URL = vm.envString("POLYGON_RPC_URL");

    uint256 mainnetFork;
    uint256 polygonFork;

    function setUp() external {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        polygonFork = vm.createFork(POLYGON_RPC_URL);
    }

    function test_ExecutorOnBridge(uint256 offerAmount, uint256 numDepositors) internal {
        numDepositors = bound(numDepositors, 1, 20);
        offerAmount = bound(offerAmount, 1e6, type(uint48).max);

        (
            bytes32 marketHash,
            address payable[] memory depositorWallets,
            address[] memory depositors,
            uint256[] memory depositAmounts,
            bytes memory encodedPayload
        ) = _bridgeDeposits(offerAmount, numDepositors);

        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);
    }

    function _bridgeDeposits(
        uint256 offerAmount,
        uint256 numDepositors
    )
        internal
        returns (
            bytes32 marketHash,
            address payable[] memory depositorWallets,
            address[] memory depositors,
            uint256[] memory depositAmounts,
            bytes memory encodedPayload
        )
    {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory predepositTokens = new ERC20[](1);
        IStargate[] memory stargates = new IStargate[](1);

        predepositTokens[0] = ERC20(USDC_MAINNET_ADDRESS); // USDC on ETH Mainnet
        stargates[0] = IStargate(STARGATE_USDC_POOL_MAINNET_ADDRESS); // Stargate USDC Pool on ETH Mainnet

        // Locker for bridging to IOTA (Stargate Hydra on destination chain)
        PredepositLocker predepositLocker = new PredepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), predepositTokens, stargates, recipeMarketHub);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(PredepositLocker.deposit.selector, address(walletHelper), USDC_MAINNET_ADDRESS, address(predepositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(PredepositLocker.withdraw.selector, address(predepositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        marketHash = recipeMarketHub.createMarket(USDC_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        depositorWallets = new address payable[](numDepositors);
        depositors = new address[](numDepositors);
        depositAmounts = new uint256[](numDepositors);
        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            depositors[i] = ap;

            // Fund the AP
            deal(USDC_MAINNET_ADDRESS, ap, offerAmount);

            vm.startPrank(ap);

            // Approve the market hub to spend the tokens
            ERC20(USDC_MAINNET_ADDRESS).approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }

            // Record the logs to capture Transfer events to get Weiroll wallet address
            vm.recordLogs();
            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
            // Extract the Weiroll wallet address (the 'to' address from the Transfer event - third event in logs)
            address payable weirollWallet = payable(address(uint160(uint256(vm.getRecordedLogs()[0].topics[2]))));

            depositorWallets[i] = weirollWallet;
            depositAmounts[i] = predepositLocker.marketHashToDepositorToAmountDeposited(marketHash, weirollWallet);
        }

        vm.startPrank(OWNER_ADDRESS);
        predepositLocker.setMulitsig(marketHash, MULTISIG_ADDRESS);
        vm.stopPrank();

        vm.startPrank(MULTISIG_ADDRESS);
        predepositLocker.setGreenLight(marketHash, true);
        vm.stopPrank();

        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.startPrank(IP_ADDRESS);
        predepositLocker.bridge{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
        vm.stopPrank();
    }
}
