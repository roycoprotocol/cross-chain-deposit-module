// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the PredepositLocker contract and its dependencies
import { PredepositLocker, RecipeMarketHubBase, ERC20 } from "src/PredepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, RewardStyle, Points } from "test/utils/RecipeMarketHubTestBase.sol";
import { IStargate } from "src/interfaces/IStargate.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { WeirollWalletHelper } from "test/utils/WeirollWalletHelper.sol";

// Test depositing and withdrawing to/from the PredepositLocker through a Royco Market
// This will simulate the expected behaviour on the source chain of a Predeposit Campaign
contract Test_DepositsAndWithdrawals_PredepositLocker is RecipeMarketHubTestBase {
    using FixedPointMathLib for uint256;

    address IP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    ERC20[] public predepositTokens;
    IStargate[] public stargates;

    PredepositLocker predepositLocker;
    WeirollWalletHelper walletHelper;

    uint256 frontendFee;
    bytes32 marketHash;

    function setUp() external {
        walletHelper = new WeirollWalletHelper();

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        predepositLocker = new PredepositLocker(OWNER_ADDRESS, 0, address(0), predepositTokens, stargates, recipeMarketHub);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(PredepositLocker.deposit.selector, address(walletHelper), address(mockLiquidityToken), address(predepositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(PredepositLocker.withdraw.selector, address(predepositLocker));

        frontendFee = recipeMarketHub.minimumFrontendFee();
        marketHash = recipeMarketHub.createMarket(address(mockLiquidityToken), 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);
    }

    function test_Deposits(uint256 offerAmount, uint256 numDepositors) external {
        numDepositors = bound(numDepositors, 1, 20);
        offerAmount = bound(offerAmount, 1e18, type(uint96).max);

        assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), 0);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        uint256 filledSoFar;

        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }
            // Mint liquidity tokens to the AP to fill the offer
            mockLiquidityToken.mint(ap, offerAmount);

            vm.startPrank(ap);
            mockLiquidityToken.approve(address(recipeMarketHub), offerAmount);

            vm.expectEmit(false, true, false, false, address(mockLiquidityToken));
            emit ERC20.Transfer(address(0), address(predepositLocker), fillAmount);

            vm.expectEmit(true, false, false, false, address(predepositLocker));
            emit PredepositLocker.UserDeposited(marketHash, address(0), fillAmount);

            // Record the logs to capture Transfer events to get Weiroll wallet address
            vm.recordLogs();
            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();

            // Extract the Weiroll wallet address (the 'to' address from the Transfer event - third event in logs)
            address weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[0].topics[2])));

            if (i == (numDepositors - 1)) {
                assertEq(predepositLocker.marketHashToDepositorToAmountDeposited(marketHash, weirollWallet), offerAmount - filledSoFar);
            } else {
                assertEq(predepositLocker.marketHashToDepositorToAmountDeposited(marketHash, weirollWallet), fillAmount);
                filledSoFar += fillAmount;
                assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), filledSoFar);
            }

            assertEq(mockLiquidityToken.balanceOf(weirollWallet), 0);
        }

        assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), offerAmount);
    }

    function test_Withdrawals(uint256 offerAmount, uint256 numDepositors, uint256 numWithdrawals) external {
        numDepositors = bound(numDepositors, 1, 20);
        numWithdrawals = bound(numWithdrawals, 1, numDepositors);
        offerAmount = bound(offerAmount, 1e18, type(uint96).max);

        assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), 0);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        address[] memory aps = new address[](numDepositors);
        address[] memory depositorWallets = new address[](numDepositors);

        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            aps[i] = ap;

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }

            // Mint liquidity tokens to the AP to fill the offer
            mockLiquidityToken.mint(ap, offerAmount);
            vm.startPrank(ap);
            mockLiquidityToken.approve(address(recipeMarketHub), offerAmount);

            vm.expectEmit(false, true, false, false, address(mockLiquidityToken));
            emit ERC20.Transfer(address(0), address(predepositLocker), fillAmount);

            vm.expectEmit(true, false, false, false, address(predepositLocker));
            emit PredepositLocker.UserDeposited(marketHash, address(0), fillAmount);

            // Record the logs to capture Transfer events to get Weiroll wallet address
            vm.recordLogs();
            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();

            // Extract the Weiroll wallet address (the 'to' address from the Transfer event - third event in logs)
            address weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[0].topics[2])));

            depositorWallets[i] = weirollWallet;
        }

        assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), offerAmount);

        uint256 withdrawnSoFar;

        for (uint256 i = 0; i < numWithdrawals; i++) {
            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = offerAmount - (fillAmount * (numDepositors - 1));
            }

            vm.startPrank(aps[i]);

            vm.expectEmit(true, true, false, true, address(mockLiquidityToken));
            emit ERC20.Transfer(address(predepositLocker), depositorWallets[i], fillAmount);

            vm.expectEmit(true, false, false, true, address(predepositLocker));
            emit PredepositLocker.UserWithdrawn(marketHash, depositorWallets[i], fillAmount);

            recipeMarketHub.forfeit(depositorWallets[i], true);
            vm.stopPrank();

            withdrawnSoFar += fillAmount;

            assertEq(predepositLocker.marketHashToDepositorToAmountDeposited(marketHash, depositorWallets[i]), 0);

            assertEq(mockLiquidityToken.balanceOf(depositorWallets[i]), fillAmount);
            assertEq(mockLiquidityToken.balanceOf(address(predepositLocker)), offerAmount - withdrawnSoFar);
        }
    }
}
