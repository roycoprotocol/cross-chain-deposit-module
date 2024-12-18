// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the DepositLocker contract and its dependencies
import { DepositLocker, RecipeMarketHubBase, ERC20, IWETH } from "../src/core/DepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, RewardStyle, Points } from "./utils/RecipeMarketHubTestBase.sol";
import { IOFT } from "../src/interfaces/IOFT.sol";

// Test Bridging Deposits on ETH Mainnet fork
contract Test_BridgeDeposits_DepositLocker is RecipeMarketHubTestBase {
    address IP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    uint256 mainnetFork;

    function setUp() external {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
    }

    function test_Bridge_USDC_Deposits(uint256 offerAmount, uint256 numDepositors) external {
        offerAmount = bound(offerAmount, 1e6, 10_000_000e6);

        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](2);
        IOFT[] memory lzV2OFTs = new IOFT[](2);

        depositTokens[0] = ERC20(USDC_MAINNET_ADDRESS); // USDC on ETH Mainnet
        lzV2OFTs[0] = IOFT(STARGATE_USDC_POOL_MAINNET_ADDRESS); // Stargate USDC Pool on ETH Mainnet
        depositTokens[1] = ERC20(WBTC_MAINNET_ADDRESS); // WBTC on ETH Mainnet
        lzV2OFTs[1] = IOFT(WBTC_OFT_ADAPTER_MAINNET_ADDRESS); // WBTC OFT Adapter on ETH Mainnet

        // Locker for bridging to IOTA (Stargate Hydra on destination chain)
        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), GREEN_LIGHTER_ADDRESS, recipeMarketHub, UNISWAP_V2_MAINNET_ROUTER_ADDRESS, lzV2OFTs);

        numDepositors = bound(numDepositors, 1, depositLocker.MAX_DEPOSITORS_PER_BRIDGE());

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), USDC_MAINNET_ADDRESS, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        bytes32 marketHash =
            recipeMarketHub.createMarket(USDC_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        address[] memory depositorWallets = new address[](numDepositors);
        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            depositorWallets[i] = ap;

            // Fund the AP
            deal(USDC_MAINNET_ADDRESS, ap, offerAmount);

            vm.startPrank(ap);

            // Approve the market hub to spend the tokens
            ERC20(USDC_MAINNET_ADDRESS).approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }
            bytes32[] memory ipOfferHashes = new bytes32[](1);
            ipOfferHashes[0] = offerHash;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = fillAmount;

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.turnGreenLightOn(marketHash);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, USDC_MAINNET_ADDRESS);
        emit ERC20.Transfer(address(depositLocker), address(depositLocker.tokenToLzV2OFT(ERC20(USDC_MAINNET_ADDRESS))), offerAmount);

        vm.expectEmit(false, false, true, false, address(depositLocker));
        emit DepositLocker.SingleTokensBridgedToDestination(marketHash, 0, new address[](0), bytes32(0), 0, offerAmount);

        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION() + 1);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleTokens{ value: 5 ether }(marketHash, depositorWallets);
        vm.stopPrank();
    }

    function test_Bridge_wETH_Deposits(uint256 offerAmount, uint256 numDepositors) external {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        offerAmount = bound(offerAmount, 1e6, ERC20(WETH_MAINNET_ADDRESS).totalSupply());

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](2);
        IOFT[] memory lzV2OFTs = new IOFT[](2);

        depositTokens[0] = ERC20(USDC_MAINNET_ADDRESS); // USDC on ETH Mainnet
        lzV2OFTs[0] = IOFT(STARGATE_USDC_POOL_MAINNET_ADDRESS); // Stargate USDC Pool on ETH Mainnet
        depositTokens[1] = ERC20(WETH_MAINNET_ADDRESS); // WETH on ETH Mainnet
        lzV2OFTs[1] = IOFT(STARGATE_POOL_NATIVE_MAINNET_ADDRESS); // Stargate native pool on ETH Mainnet

        // Locker for bridging to SEI (Stargate Hydra on destination chain)
        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_280, address(0xbeef), GREEN_LIGHTER_ADDRESS, recipeMarketHub, UNISWAP_V2_MAINNET_ROUTER_ADDRESS, lzV2OFTs);

        numDepositors = bound(numDepositors, 1, depositLocker.MAX_DEPOSITORS_PER_BRIDGE());

        vm.assume(_removeDust(offerAmount / numDepositors, 18, 6) > 0);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), WETH_MAINNET_ADDRESS, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        bytes32 marketHash =
            recipeMarketHub.createMarket(WETH_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        address[] memory depositorWallets = new address[](numDepositors);
        uint256 filledSoFar;
        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            depositorWallets[i] = ap;

            // Fund the AP
            deal(WETH_MAINNET_ADDRESS, ap, offerAmount);

            vm.startPrank(ap);

            // Approve the market hub to spend the tokens
            ERC20(WETH_MAINNET_ADDRESS).approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = offerAmount - (fillAmount * (numDepositors - 1));
            }

            fillAmount = _removeDust(fillAmount, 18, 6);

            filledSoFar += fillAmount;

            // AP Fills the offer (no funding vault)
            bytes32[] memory ipOfferHashes = new bytes32[](1);
            ipOfferHashes[0] = offerHash;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = fillAmount;

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.turnGreenLightOn(marketHash);
        vm.stopPrank();

        vm.expectEmit(true, false, false, false, address(depositLocker));
        emit DepositLocker.SingleTokensBridgedToDestination(marketHash, 0, new address[](0), bytes32(0), 0, filledSoFar);
        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION() + 1);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleTokens{ value: 5 ether }(marketHash, depositorWallets);
        vm.stopPrank();
    }

    function test_Bridge_wBTC_Deposits(uint256 offerAmount, uint256 numDepositors) external {
        offerAmount = bound(offerAmount, 1e6, 1000e8);

        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](2);
        IOFT[] memory lzV2OFTs = new IOFT[](2);

        depositTokens[0] = ERC20(USDC_MAINNET_ADDRESS); // USDC on ETH Mainnet
        lzV2OFTs[0] = IOFT(STARGATE_USDC_POOL_MAINNET_ADDRESS); // Stargate USDC Pool on ETH Mainnet
        depositTokens[1] = ERC20(WBTC_MAINNET_ADDRESS); // WBTC on ETH Mainnet
        lzV2OFTs[1] = IOFT(WBTC_OFT_ADAPTER_MAINNET_ADDRESS); // WBTC OFT Adapter on ETH Mainnet

        // Locker for bridging to Avax
        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_106, address(0xbeef), GREEN_LIGHTER_ADDRESS, recipeMarketHub, UNISWAP_V2_MAINNET_ROUTER_ADDRESS, lzV2OFTs);

        numDepositors = bound(numDepositors, 1, depositLocker.MAX_DEPOSITORS_PER_BRIDGE());

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), WBTC_MAINNET_ADDRESS, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        bytes32 marketHash =
            recipeMarketHub.createMarket(WBTC_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        address[] memory depositorWallets = new address[](numDepositors);
        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            depositorWallets[i] = ap;

            // Fund the AP
            deal(WBTC_MAINNET_ADDRESS, ap, offerAmount);

            vm.startPrank(ap);

            // Approve the market hub to spend the tokens
            ERC20(WBTC_MAINNET_ADDRESS).approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }

            // AP Fills the offer (no funding vault)
            bytes32[] memory ipOfferHashes = new bytes32[](1);
            ipOfferHashes[0] = offerHash;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = fillAmount;

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.turnGreenLightOn(marketHash);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, WBTC_MAINNET_ADDRESS);
        emit ERC20.Transfer(address(depositLocker), WBTC_OFT_ADAPTER_MAINNET_ADDRESS, offerAmount);

        vm.expectEmit(false, false, true, false, address(depositLocker));
        emit DepositLocker.SingleTokensBridgedToDestination(marketHash, 0, new address[](0), bytes32(0), 0, offerAmount);
        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION() + 1);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleTokens{ value: 5 ether }(marketHash, depositorWallets);
        vm.stopPrank();
    }

    function test_Bridge_LpToken_wETH_USDC_Deposits(uint256 offerAmount, uint256 numDepositors, uint256 randomSeed) external {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        randomSeed = bound(randomSeed, 1, 1000);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](2);
        IOFT[] memory lzV2OFTs = new IOFT[](2);

        depositTokens[0] = ERC20(USDC_MAINNET_ADDRESS); // USDC on ETH Mainnet
        lzV2OFTs[0] = IOFT(STARGATE_USDC_POOL_MAINNET_ADDRESS); // Stargate USDC Pool on ETH Mainnet
        depositTokens[1] = ERC20(WETH_MAINNET_ADDRESS); // wETH on ETH Mainnet
        lzV2OFTs[1] = IOFT(STARGATE_POOL_NATIVE_MAINNET_ADDRESS); // Stargate native pool on ETH Mainnet

        // Locker for bridging to IOTA (hydra on IOTA so its feeless)
        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), GREEN_LIGHTER_ADDRESS, recipeMarketHub, UNISWAP_V2_MAINNET_ROUTER_ADDRESS, lzV2OFTs);

        numDepositors = bound(numDepositors, 1, depositLocker.MAX_DEPOSITORS_PER_BRIDGE());

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), UNI_V2_wETH_USDC_PAIR, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        bytes32 marketHash =
            recipeMarketHub.createMarket(UNI_V2_wETH_USDC_PAIR, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        address[] memory depositorWallets = new address[](numDepositors);
        uint256 totalLiquidity = 0;
        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            depositorWallets[i] = ap;

            // Fund the AP
            deal(ap, 1e18 * randomSeed);
            deal(USDC_MAINNET_ADDRESS, ap, 3000e6 * randomSeed);

            vm.startPrank(ap);

            IWETH(WETH_MAINNET_ADDRESS).deposit{ value: 1e18 * randomSeed }();

            ERC20(WETH_MAINNET_ADDRESS).approve(address(UNISWAP_V2_MAINNET_ROUTER_ADDRESS), type(uint256).max);
            ERC20(USDC_MAINNET_ADDRESS).approve(address(UNISWAP_V2_MAINNET_ROUTER_ADDRESS), type(uint256).max);

            (,, uint256 liquidity) = UNISWAP_V2_MAINNET_ROUTER_ADDRESS.addLiquidity(
                WETH_MAINNET_ADDRESS, USDC_MAINNET_ADDRESS, 1e18 * randomSeed, 3000e6 * randomSeed, 0, 0, ap, block.timestamp
            );

            ERC20(UNI_V2_wETH_USDC_PAIR).approve(address(recipeMarketHub), liquidity);

            totalLiquidity += liquidity;
            vm.stopPrank();
        }

        offerAmount = bound(offerAmount, totalLiquidity, totalLiquidity * 10);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        for (uint256 i = 0; i < numDepositors; i++) {
            vm.startPrank(depositorWallets[i]);

            // AP Fills the offer (no funding vault)
            bytes32[] memory ipOfferHashes = new bytes32[](1);
            ipOfferHashes[0] = offerHash;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = totalLiquidity / numDepositors;

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.stopPrank();

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setLpMarketOwner(marketHash, IP_ADDRESS);
        vm.stopPrank();

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.turnGreenLightOn(marketHash);
        vm.stopPrank();

        vm.expectEmit(true, true, false, false, USDC_MAINNET_ADDRESS);
        emit ERC20.Transfer(address(depositLocker), address(depositLocker.tokenToLzV2OFT(ERC20(USDC_MAINNET_ADDRESS))), 0);

        vm.expectEmit(true, true, false, false, address(depositLocker));
        emit DepositLocker.LpTokensBridgedToDestination(
            marketHash, 1, new address[](0), bytes32(0), 0, ERC20(address(0)), 0, bytes32(0), 0, ERC20(address(0)), 0
        );
        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION() + 1);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeLpTokens{ value: 5 ether }(marketHash, 0, 0, depositorWallets);
        vm.stopPrank();

        // Ensure that the nonce was incremented
        assertEq(depositLocker.ccdmNonce(), 2);
    }
}
