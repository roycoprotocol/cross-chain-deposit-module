// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the DepositLocker contract and its dependencies
import { DepositLocker, RecipeMarketHubBase, ERC20, IWETH } from "../src/core/DepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, WeirollWallet, RewardStyle, Points } from "./utils/RecipeMarketHubTestBase.sol";
import { DepositExecutor } from "../src/core/DepositExecutor.sol";
import { IOFT } from "../src/interfaces/IOFT.sol";
import { Vm } from "../lib/forge-std/src/Vm.sol";
import { OFTComposeMsgCodec } from "../src/libraries/OFTComposeMsgCodec.sol";
import { CCDMFeeLib } from "../src/libraries/CCDMFeeLib.sol";

// Test deploying deposits via weiroll recipes post bridge
contract E2E_Test_DepositExecutor is RecipeMarketHubTestBase {
    using OFTComposeMsgCodec for bytes;

    address IP_ADDRESS;
    address AP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");
    string POLYGON_RPC_URL = vm.envString("POLYGON_RPC_URL");

    uint256 mainnetFork;
    uint256 polygonFork;

    struct BridgeDepositsResult {
        bytes32 marketHash;
        address[] depositors;
        uint256[] depositAmounts;
        address depositLocker;
        bytes encodedPayload;
        bytes32 guid;
        uint256 actualNumberOfDepositors;
    }

    struct DepositExecutorSetup {
        DepositExecutor depositExecutor;
        WeirollWalletHelper walletHelper;
    }

    /**
     * @notice Sets up the mainnet and polygon forks for testing.
     */
    function setUp() external {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        polygonFork = vm.createFork(POLYGON_RPC_URL);
    }

    /**
     * @notice Tests the DepositExecutor's functionality during a bridge operation.
     * @param offerAmount The amount offered for deposit.
     * @param numDepositors The number of depositors participating.
     * @param unlockTimestamp The timestamp when deposits can be unlocked.
     */
    function test_ExecutorOnBridge_WithDepositRecipeExecution(
        uint256 offerAmount,
        uint256 numDepositors,
        uint256 unlockTimestamp,
        uint256 dustAmount
    )
        external
    {
        offerAmount = bound(offerAmount, 10e6, 1_000_000e6);
        dustAmount = bound(dustAmount, 0, 1_000_000e6);

        // Simulate bridge
        BridgeDepositsResult memory bridgeResult = _bridgeDeposits(offerAmount, numDepositors);

        numDepositors = bridgeResult.actualNumberOfDepositors;

        // Receive bridged funds on Polygon and execute recipes for depositor's wallet
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        unlockTimestamp = bound(unlockTimestamp, block.timestamp + 1 hours, block.timestamp + 7 days);

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        address[] memory validLzOFTs = new address[](1);
        validLzOFTs[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS;

        DepositExecutor depositExecutor = new DepositExecutor(
            OWNER_ADDRESS,
            POLYGON_LZ_ENDPOINT,
            CAMPAIGN_VERIFIER_ADDRESS,
            address(0),
            30_101,
            bridgeResult.depositLocker,
            validLzOFTs,
            new bytes32[](0),
            new address[](0)
        );

        vm.startPrank(OWNER_ADDRESS);
        depositExecutor.setNewCampaignOwner(bridgeResult.marketHash, IP_ADDRESS);
        vm.stopPrank();

        DepositExecutor.Recipe memory DEPOSIT_RECIPE =
            _buildAaveSupplyRecipe(address(walletHelper), USDC_POLYGON_ADDRESS, AAVE_POOL_V3_POLYGON, aUSDC_POLYGON, address(depositExecutor));

        vm.startPrank(IP_ADDRESS);
        depositExecutor.initializeCampaign(bridgeResult.marketHash, unlockTimestamp, ERC20(aUSDC_POLYGON), DEPOSIT_RECIPE);
        vm.stopPrank();

        vm.startPrank(CAMPAIGN_VERIFIER_ADDRESS);
        depositExecutor.verifyCampaign(bridgeResult.marketHash, depositExecutor.getCampaignVerificationHash(bridgeResult.marketHash));
        vm.stopPrank();

        // Fund the Executor (bridge simulation)
        deal(USDC_POLYGON_ADDRESS, address(depositExecutor), offerAmount);

        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        depositExecutor.lzCompose{ gas: CCDMFeeLib.estimateDestinationGasLimit(numDepositors) }(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            bridgeResult.guid,
            OFTComposeMsgCodec.encode(
                uint64(0),
                uint32(30_101),
                offerAmount,
                abi.encodePacked(bytes32(uint256(uint160(bridgeResult.depositLocker))), getSlice(188, bridgeResult.encodedPayload))
            ),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // Check that all weiroll wallets were created and executed as expected
        Vm.Log[] memory logs = vm.getRecordedLogs();
        WeirollWallet weirollWalletCreatedForBridge = WeirollWallet(payable(abi.decode(logs[1].data, (address))));

        // Check wallet state is correct
        assertEq(weirollWalletCreatedForBridge.owner(), address(0));
        assertEq(weirollWalletCreatedForBridge.recipeMarketHub(), address(depositExecutor));
        assertEq(weirollWalletCreatedForBridge.amount(), 0);
        assertEq(weirollWalletCreatedForBridge.lockedUntil(), unlockTimestamp);
        assertEq(weirollWalletCreatedForBridge.isForfeitable(), false);
        assertEq(weirollWalletCreatedForBridge.marketHash(), bridgeResult.marketHash);
        assertEq(weirollWalletCreatedForBridge.executed(), false);
        assertEq(weirollWalletCreatedForBridge.forfeited(), false);
        // Check that deposit amount was not sent to the wallet (will be sent when executing deposit recipe)
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(depositExecutor)), offerAmount);

        address[] memory weirollWallets = new address[](1);
        weirollWallets[0] = address(weirollWalletCreatedForBridge);

        vm.startPrank(IP_ADDRESS);
        depositExecutor.executeDepositRecipes(bridgeResult.marketHash, weirollWallets);
        vm.stopPrank();

        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);

        // Simulate a dust amount left in the wallet
        deal(USDC_POLYGON_ADDRESS, address(weirollWalletCreatedForBridge), dustAmount);

        uint256 initialReceiptTokenBalance = ERC20(aUSDC_POLYGON).balanceOf(address(weirollWalletCreatedForBridge));

        vm.warp(unlockTimestamp);

        address[] memory walletsToWithdraw = new address[](1);
        walletsToWithdraw[0] = address(weirollWalletCreatedForBridge);

        for (uint256 i = 0; i < bridgeResult.depositors.length; ++i) {
            vm.warp(unlockTimestamp + (i * 1 hours));

            // Withdraw without executing deposit recipes
            vm.startPrank(bridgeResult.depositors[i]);
            depositExecutor.withdraw(walletsToWithdraw);
            vm.stopPrank();

            // Assert that depositor got their receipt tokens and any interest.
            assertGe(ERC20(aUSDC_POLYGON).balanceOf(bridgeResult.depositors[i]), ((initialReceiptTokenBalance * bridgeResult.depositAmounts[i]) / offerAmount));
            if (dustAmount > 1e6) {
                assertApproxEqRel(
                    ERC20(USDC_POLYGON_ADDRESS).balanceOf(bridgeResult.depositors[i]), ((dustAmount * bridgeResult.depositAmounts[i]) / offerAmount), 0.01e18
                );
            }
        }
        assertEq(ERC20(aUSDC_POLYGON).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        if (dustAmount > 1e6) {
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        }
    }

    /**
     * @notice Tests the DepositExecutor's functionality during a bridge operation.
     * @param offerAmount The amount offered for deposit.
     * @param numDepositors The number of depositors participating.
     * @param unlockTimestamp The timestamp when deposits can be unlocked.
     */
    function test_ExecutorOnBridge_NoDepositRecipeExecution(uint256 offerAmount, uint256 numDepositors, uint256 unlockTimestamp) external {
        offerAmount = bound(offerAmount, 1e6, type(uint48).max);
        // Simulate bridge
        BridgeDepositsResult memory bridgeResult = _bridgeDeposits(offerAmount, numDepositors);

        numDepositors = bridgeResult.actualNumberOfDepositors;

        // Receive bridged funds on Polygon and execute recipes for depositor's wallet
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        unlockTimestamp = bound(unlockTimestamp, block.timestamp + 1 hours, block.timestamp + 120 days);

        weirollImplementation = new WeirollWallet();

        address[] memory validLzOFTs = new address[](1);
        validLzOFTs[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS;

        DepositExecutor depositExecutor = new DepositExecutor(
            OWNER_ADDRESS,
            POLYGON_LZ_ENDPOINT,
            CAMPAIGN_VERIFIER_ADDRESS,
            address(0),
            30_101,
            bridgeResult.depositLocker,
            validLzOFTs,
            new bytes32[](0),
            new address[](0)
        );

        vm.startPrank(OWNER_ADDRESS);
        depositExecutor.setNewCampaignOwner(bridgeResult.marketHash, IP_ADDRESS);
        vm.stopPrank();

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        DepositExecutor.Recipe memory DEPOSIT_RECIPE =
            _buildAaveSupplyRecipe(address(walletHelper), USDC_POLYGON_ADDRESS, AAVE_POOL_V3_POLYGON, aUSDC_POLYGON, address(depositExecutor));

        vm.startPrank(IP_ADDRESS);
        depositExecutor.initializeCampaign(bridgeResult.marketHash, unlockTimestamp, ERC20(aUSDC_POLYGON), DEPOSIT_RECIPE);
        vm.stopPrank();

        vm.startPrank(CAMPAIGN_VERIFIER_ADDRESS);
        depositExecutor.verifyCampaign(bridgeResult.marketHash, depositExecutor.getCampaignVerificationHash(bridgeResult.marketHash));
        vm.stopPrank();

        // Fund the Executor (bridge simulation)
        deal(USDC_POLYGON_ADDRESS, address(depositExecutor), offerAmount);

        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        depositExecutor.lzCompose{ gas: CCDMFeeLib.estimateDestinationGasLimit(numDepositors) }(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            bridgeResult.guid,
            OFTComposeMsgCodec.encode(
                uint64(0),
                uint32(30_101),
                offerAmount,
                abi.encodePacked(bytes32(uint256(uint160(bridgeResult.depositLocker))), getSlice(188, bridgeResult.encodedPayload))
            ),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // Check that all weiroll wallets were created and executed as expected
        Vm.Log[] memory logs = vm.getRecordedLogs();
        WeirollWallet weirollWalletCreatedForBridge = WeirollWallet(payable(abi.decode(logs[1].data, (address))));

        // Check wallet state is correct
        assertEq(weirollWalletCreatedForBridge.owner(), address(0));
        assertEq(weirollWalletCreatedForBridge.recipeMarketHub(), address(depositExecutor));
        assertEq(weirollWalletCreatedForBridge.amount(), 0);
        assertEq(weirollWalletCreatedForBridge.lockedUntil(), unlockTimestamp);
        assertEq(weirollWalletCreatedForBridge.isForfeitable(), false);
        assertEq(weirollWalletCreatedForBridge.marketHash(), bridgeResult.marketHash);
        assertEq(weirollWalletCreatedForBridge.executed(), false);
        assertEq(weirollWalletCreatedForBridge.forfeited(), false);
        // Check that deposit amount was not sent to the wallet (will be sent when executing deposit recipe)
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(depositExecutor)), offerAmount);

        vm.warp(unlockTimestamp);

        address[] memory walletsToWithdraw = new address[](1);
        walletsToWithdraw[0] = address(weirollWalletCreatedForBridge);

        for (uint256 i = 0; i < bridgeResult.depositors.length; ++i) {
            // Expect transfer call and event
            vm.expectCall(USDC_POLYGON_ADDRESS, abi.encodeCall(ERC20.transfer, (bridgeResult.depositors[i], bridgeResult.depositAmounts[i])));
            vm.expectEmit(true, true, false, true, USDC_POLYGON_ADDRESS);
            emit ERC20.Transfer(address(depositExecutor), bridgeResult.depositors[i], bridgeResult.depositAmounts[i]);

            // Withdraw without executing deposit recipes
            vm.startPrank(bridgeResult.depositors[i]);
            depositExecutor.withdraw(walletsToWithdraw);
            vm.stopPrank();

            // Assert that depositor got their tokens
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(bridgeResult.depositors[i]), bridgeResult.depositAmounts[i]);
        }
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletCreatedForBridge)), 0);
    }

    /**
     * @notice Simulates bridging deposits by setting up the environment, creating depositors, and bridging tokens.
     * @param offerAmount The total amount offered for deposits.
     * @param numDepositors The number of depositors to simulate.
     * @return result A struct containing all relevant data about the bridged deposits.
     */
    function _bridgeDeposits(uint256 offerAmount, uint256 numDepositors) internal returns (BridgeDepositsResult memory result) {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;
        vm.makePersistent(IP_ADDRESS);

        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](2);
        IOFT[] memory lzV2OFTs = new IOFT[](2);

        depositTokens[0] = ERC20(USDC_MAINNET_ADDRESS); // USDC on ETH Mainnet
        lzV2OFTs[0] = IOFT(STARGATE_USDC_POOL_MAINNET_ADDRESS); // Stargate USDC Pool on ETH Mainnet
        depositTokens[1] = ERC20(WBTC_MAINNET_ADDRESS); // WBTC on ETH Mainnet
        lzV2OFTs[1] = IOFT(WBTC_OFT_ADAPTER_MAINNET_ADDRESS); // WBTC OFT Adapter on ETH Mainnet

        // Locker for bridging to IOTA (Stargate Hydra on destination chain)
        DepositLocker depositLocker = new DepositLocker(
            OWNER_ADDRESS,
            30_284,
            address(0xbeef),
            GREEN_LIGHTER_ADDRESS,
            recipeMarketHub,
            IWETH(WETH_MAINNET_ADDRESS),
            UNISWAP_V2_MAINNET_ROUTER_ADDRESS,
            lzV2OFTs
        );

        result.depositLocker = address(depositLocker);

        numDepositors = bound(numDepositors, 1, depositLocker.MAX_DEPOSITORS_PER_BRIDGE());
        result.actualNumberOfDepositors = numDepositors;

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), USDC_MAINNET_ADDRESS, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        uint256 frontendFee = recipeMarketHub.minimumFrontendFee();
        result.marketHash = recipeMarketHub.createMarket(USDC_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(result.marketHash, offerAmount, IP_ADDRESS);

        result.depositors = new address[](numDepositors);
        result.depositAmounts = new uint256[](numDepositors);

        for (uint256 i = 0; i < numDepositors; i++) {
            (address ap,) = makeAddrAndKey(string(abi.encode(i)));
            result.depositors[i] = ap;

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
            bytes32[] memory ipOfferHashes = new bytes32[](1);
            ipOfferHashes[0] = offerHash;
            uint256[] memory fillAmounts = new uint256[](1);
            fillAmounts[0] = fillAmount;

            // AP Fills the offer (no funding vault)
            recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();

            (uint256 totalAmountDeposited,) = depositLocker.marketHashToDepositorToDepositorInfo(result.marketHash, ap);
            result.depositAmounts[i] = totalAmountDeposited;
        }

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.turnGreenLightOn(result.marketHash);
        vm.stopPrank();

        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION() + 1);

        vm.recordLogs();
        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleTokens{ value: 5 ether }(result.marketHash, result.depositors);
        vm.stopPrank();

        // Get the encoded payload which will be passed in compose call on the destination chain
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (result.encodedPayload,,) = abi.decode(logs[logs.length - 3].data, (bytes, bytes, address));
        result.guid = logs[logs.length - 1].topics[1];
    }

    /**
     * @notice Extracts a slice of bytes from the given data starting at a specific index.
     * @param begin The starting index for the slice.
     * @param data The bytes data to slice.
     * @return A new bytes array containing the sliced data.
     */
    function getSlice(uint256 begin, bytes memory data) internal pure returns (bytes memory) {
        bytes memory a = new bytes(data.length - begin);
        for (uint256 i = 0; i < data.length - begin; i++) {
            a[i] = data[i + begin];
        }
        return a;
    }
}
