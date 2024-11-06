// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the DepositLocker contract and its dependencies
import { DepositLocker, RecipeMarketHubBase, ERC20, DualToken, IWETH, DepositType } from "src/core/DepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, RewardStyle, Points } from "test/utils/RecipeMarketHubTestBase.sol";
import { IOFT } from "src/interfaces/IOFT.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Test Bridging Deposits on ETH Mainnet fork
contract Test_BridgeDeposits_DepositLocker is RecipeMarketHubTestBase {
    using FixedPointMathLib for uint256;

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
            new DepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), recipeMarketHub, IWETH(WETH_MAINNET_ADDRESS), depositTokens, lzV2OFTs);

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

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setMulitsig(marketHash, MULTISIG_ADDRESS);
        vm.stopPrank();

        vm.startPrank(MULTISIG_ADDRESS);
        depositLocker.setGreenLight(marketHash, true);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, USDC_MAINNET_ADDRESS);
        emit ERC20.Transfer(address(depositLocker), address(depositLocker.tokenToLzV2OFT(ERC20(USDC_MAINNET_ADDRESS))), offerAmount);

        vm.expectEmit(false, false, true, false, address(depositLocker));
        emit DepositLocker.SingleTokenBridgeToDestinationChain(marketHash, bytes32(0), 0, offerAmount);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleToken{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
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
            new DepositLocker(OWNER_ADDRESS, 30_280, address(0xbeef), recipeMarketHub, IWETH(WETH_MAINNET_ADDRESS), depositTokens, lzV2OFTs);

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
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setMulitsig(marketHash, MULTISIG_ADDRESS);
        vm.stopPrank();

        vm.startPrank(MULTISIG_ADDRESS);
        depositLocker.setGreenLight(marketHash, true);
        vm.stopPrank();

        vm.expectEmit(true, false, false, false, address(depositLocker));
        emit DepositLocker.SingleTokenBridgeToDestinationChain(marketHash, bytes32(0), 0, filledSoFar);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleToken{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
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
            new DepositLocker(OWNER_ADDRESS, 30_106, address(0xbeef), recipeMarketHub, IWETH(WETH_MAINNET_ADDRESS), depositTokens, lzV2OFTs);

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
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setMulitsig(marketHash, MULTISIG_ADDRESS);
        vm.stopPrank();

        vm.startPrank(MULTISIG_ADDRESS);
        depositLocker.setGreenLight(marketHash, true);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, WBTC_MAINNET_ADDRESS);
        emit ERC20.Transfer(address(depositLocker), WBTC_OFT_ADAPTER_MAINNET_ADDRESS, offerAmount);

        vm.expectEmit(false, false, true, false, address(depositLocker));
        emit DepositLocker.SingleTokenBridgeToDestinationChain(marketHash, bytes32(0), 0, offerAmount);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleToken{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
        vm.stopPrank();
    }

    function test_Bridge_DualToken_USDC_USDT_Deposits(uint256 offerAmount, uint256 numDepositors) external {
        offerAmount = bound(offerAmount, 1e6, 1e9);

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
        depositTokens[1] = ERC20(USDT_MAINNET_ADDRESS); // USDT on ETH Mainnet
        lzV2OFTs[1] = IOFT(STARGATE_USDT_POOL_MAINNET_ADDRESS); // Stargate USDT Pool on ETH Mainnet

        // Locker for bridging to IOTA (hydra on IOTA so its feeless)
        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), recipeMarketHub, IWETH(WETH_MAINNET_ADDRESS), depositTokens, lzV2OFTs);

        numDepositors = bound(numDepositors, 1, depositLocker.MAX_DEPOSITORS_PER_BRIDGE());

        // New DualToken
        // 1 DT = .0001 USDT and 0.00009 USDC
        DualToken dualToken =
            depositLocker.DUAL_TOKEN_FACTORY().createDualToken("USDT/USDC", "DT-0", ERC20(USDT_MAINNET_ADDRESS), ERC20(USDC_MAINNET_ADDRESS), 1e2, 0.9e1);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), address(dualToken), address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        bytes32 marketHash = recipeMarketHub.createMarket(address(dualToken), 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setMulitsig(marketHash, MULTISIG_ADDRESS);
        vm.stopPrank();

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        address[] memory depositorWallets = new address[](numDepositors);
        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            depositorWallets[i] = ap;

            // Fund the AP
            deal(USDT_MAINNET_ADDRESS, ap, offerAmount * (dualToken.amountOfTokenAPerDT()));
            deal(USDC_MAINNET_ADDRESS, ap, offerAmount * (dualToken.amountOfTokenBPerDT()));

            vm.startPrank(ap);

            SafeERC20.forceApprove(IERC20(USDT_MAINNET_ADDRESS), address(dualToken), 0);
            SafeERC20.forceApprove(IERC20(USDT_MAINNET_ADDRESS), address(dualToken), offerAmount * (dualToken.amountOfTokenAPerDT()));
            ERC20(USDC_MAINNET_ADDRESS).approve(address(dualToken), offerAmount * (dualToken.amountOfTokenBPerDT()));

            dualToken.mint(offerAmount);

            dualToken.approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(MULTISIG_ADDRESS);
        depositLocker.setGreenLight(marketHash, true);
        vm.stopPrank();

        vm.expectEmit(true, true, false, false, USDT_MAINNET_ADDRESS);
        emit ERC20.Transfer(
            address(depositLocker), address(depositLocker.tokenToLzV2OFT(ERC20(USDT_MAINNET_ADDRESS))), offerAmount * (dualToken.amountOfTokenAPerDT())
        );

        vm.expectEmit(true, true, false, false, USDC_MAINNET_ADDRESS);
        emit ERC20.Transfer(
            address(depositLocker), address(depositLocker.tokenToLzV2OFT(ERC20(USDC_MAINNET_ADDRESS))), offerAmount * (dualToken.amountOfTokenBPerDT())
        );

        uint256 nonce = depositLocker.nonce();

        vm.expectEmit(true, true, false, false, address(depositLocker));
        emit DepositLocker.DualTokenBridgeToDestinationChain(marketHash, nonce, bytes32(0), 0, 0, bytes32(0), 0, 0);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeDualToken{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
        vm.stopPrank();

        // Ensure that the nonce was incremented
        assertEq(depositLocker.nonce(), ++nonce);
    }

    function test_Bridge_DualToken_USDC_WETH_Deposits(uint256 offerAmount, uint256 numDepositors) external {
        offerAmount = bound(offerAmount, 1e6, 1e9);

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
        depositTokens[1] = ERC20(WETH_MAINNET_ADDRESS); // WETH on ETH Mainnet
        lzV2OFTs[1] = IOFT(STARGATE_POOL_NATIVE_MAINNET_ADDRESS); // Stargate Native Pool on ETH Mainnet

        // Locker for bridging to IOTA (hydra on IOTA so its feeless)
        DepositLocker depositLocker =
            new DepositLocker(OWNER_ADDRESS, 30_284, address(0xbeef), recipeMarketHub, IWETH(WETH_MAINNET_ADDRESS), depositTokens, lzV2OFTs);

        numDepositors = bound(numDepositors, 1, depositLocker.MAX_DEPOSITORS_PER_BRIDGE());

        // New DualToken
        // 1 DT = .000001 WETH and 0.0027 USDC
        DualToken dualToken =
            depositLocker.DUAL_TOKEN_FACTORY().createDualToken("WETH/USDC", "DT-0", ERC20(WETH_MAINNET_ADDRESS), ERC20(USDC_MAINNET_ADDRESS), 1e12, 0.27e2);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), address(dualToken), address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        bytes32 marketHash = recipeMarketHub.createMarket(address(dualToken), 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.setMulitsig(marketHash, MULTISIG_ADDRESS);
        vm.stopPrank();

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        address[] memory depositorWallets = new address[](numDepositors);
        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            depositorWallets[i] = ap;

            // Fund the AP
            deal(WETH_MAINNET_ADDRESS, ap, offerAmount * (dualToken.amountOfTokenAPerDT()));
            deal(USDC_MAINNET_ADDRESS, ap, offerAmount * (dualToken.amountOfTokenBPerDT()));

            vm.startPrank(ap);

            ERC20(WETH_MAINNET_ADDRESS).approve(address(dualToken), offerAmount * (dualToken.amountOfTokenAPerDT()));
            ERC20(USDC_MAINNET_ADDRESS).approve(address(dualToken), offerAmount * (dualToken.amountOfTokenBPerDT()));

            dualToken.mint(offerAmount);

            dualToken.approve(address(recipeMarketHub), offerAmount);

            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = type(uint256).max;
            }

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();
        }

        vm.startPrank(MULTISIG_ADDRESS);
        depositLocker.setGreenLight(marketHash, true);
        vm.stopPrank();

        // Make sure that the DepositLocker unwraps the correct amount of WETH
        vm.expectCall(address(depositLocker), offerAmount * (dualToken.amountOfTokenAPerDT()), "");

        vm.expectEmit(true, true, false, false, USDC_MAINNET_ADDRESS);
        emit ERC20.Transfer(
            address(depositLocker), address(depositLocker.tokenToLzV2OFT(ERC20(USDC_MAINNET_ADDRESS))), offerAmount * (dualToken.amountOfTokenBPerDT())
        );

        uint256 nonce = depositLocker.nonce();

        vm.expectEmit(true, true, false, false, address(depositLocker));
        emit DepositLocker.DualTokenBridgeToDestinationChain(marketHash, nonce, bytes32(0), 0, 0, bytes32(0), 0, 0);

        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeDualToken{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
        vm.stopPrank();

        // Ensure that the nonce was incremented
        assertEq(depositLocker.nonce(), ++nonce);
    }
}
