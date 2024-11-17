// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the DepositLocker contract and its dependencies
import { DepositLocker, RecipeMarketHubBase, ERC20, IWETH } from "src/core/DepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, WeirollWallet, RewardStyle, Points } from "test/utils/RecipeMarketHubTestBase.sol";
import { DepositExecutor } from "src/core/DepositExecutor.sol";
import { IOFT } from "src/interfaces/IOFT.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { Vm } from "lib/forge-std/src/Vm.sol";
import { OFTComposeMsgCodec } from "src/libraries/OFTComposeMsgCodec.sol";

// Test deploying deposits via weiroll recipes post bridge
contract Test_DepositExecutor is RecipeMarketHubTestBase {
    using FixedPointMathLib for uint256;

    address IP_ADDRESS;
    address AP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");
    string POLYGON_RPC_URL = vm.envString("POLYGON_RPC_URL");

    address constant POLYGON_LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint256 mainnetFork;
    uint256 polygonFork;

    struct BridgeDepositsResult {
        bytes32 marketHash;
        address[] depositors;
        uint256[] depositAmounts;
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
    function test_ExecutorOnBridge(uint256 offerAmount, uint256 numDepositors, uint256 unlockTimestamp) external {
        offerAmount = bound(offerAmount, 1e6, type(uint48).max);
        unlockTimestamp = bound(unlockTimestamp, block.timestamp, type(uint128).max);

        // Simulate bridge
        BridgeDepositsResult memory bridgeResult = _bridgeDeposits(offerAmount, numDepositors);

        numDepositors = bridgeResult.actualNumberOfDepositors;

        // Receive bridged funds on Polygon and execute recipes for depositor's wallet
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        weirollImplementation = new WeirollWallet();
        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory depositTokens = new ERC20[](1);
        address[] memory lzV2OFTs = new address[](1);

        depositTokens[0] = ERC20(USDC_POLYGON_ADDRESS); // USDC on Polygon Mainnet
        lzV2OFTs[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS; // Stargate USDC Pool on Polygon Mainnet

        DepositExecutor depositExecutor = new DepositExecutor(OWNER_ADDRESS, POLYGON_LZ_ENDPOINT, SCRIPT_VERIFIER_ADDRESS, address(0));

        vm.startPrank(OWNER_ADDRESS);
        depositExecutor.setSourceMarketOwner(bridgeResult.marketHash, IP_ADDRESS);
        vm.stopPrank();

        vm.startPrank(IP_ADDRESS);
        depositExecutor.setCampaignUnlockTimestamp(bridgeResult.marketHash, unlockTimestamp);
        vm.stopPrank();

        DepositExecutor.Recipe memory DEPOSIT_RECIPE = _buildBurnDepositRecipe(address(walletHelper), USDC_POLYGON_ADDRESS);

        vm.startPrank(IP_ADDRESS);
        depositExecutor.setCampaignDepositRecipe(bridgeResult.marketHash, DEPOSIT_RECIPE);
        vm.stopPrank();

        vm.startPrank(SCRIPT_VERIFIER_ADDRESS);
        depositExecutor.setScriptVerificationStatus(bridgeResult.marketHash, true);
        vm.stopPrank();

        // Fund the Executor (bridge simulation)
        deal(USDC_POLYGON_ADDRESS, address(depositExecutor), offerAmount);

        for (uint256 i = 0; i < numDepositors; i++) {
            // Check that tokens being deposited into weiroll wallet
            vm.expectEmit(true, false, false, false, USDC_POLYGON_ADDRESS);
            emit ERC20.Transfer(address(depositExecutor), address(0), bridgeResult.depositAmounts[i]);
        }

        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        depositExecutor.lzCompose(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            bridgeResult.guid,
            OFTComposeMsgCodec.encode(uint64(0), uint32(0), offerAmount, abi.encodePacked(bytes32(0), getSlice(188, bridgeResult.encodedPayload))),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // Check that all weiroll wallets were created and executed as expected
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < numDepositors; i++) {
            WeirollWallet weirollWalletForDepositor = WeirollWallet(payable(address(uint160(uint256(logs[i].topics[2])))));

            // Check wallet state is correct
            assertEq(weirollWalletForDepositor.owner(), bridgeResult.depositors[i]);
            assertEq(weirollWalletForDepositor.recipeMarketHub(), address(depositExecutor));
            assertEq(weirollWalletForDepositor.amount(), bridgeResult.depositAmounts[i]);
            assertEq(weirollWalletForDepositor.lockedUntil(), unlockTimestamp);
            assertEq(weirollWalletForDepositor.isForfeitable(), false);
            assertEq(weirollWalletForDepositor.marketHash(), bridgeResult.marketHash);
            assertEq(weirollWalletForDepositor.executed(), false);
            assertEq(weirollWalletForDepositor.forfeited(), false);
            // Check that deposit amount was sent to the wallet
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletForDepositor)), bridgeResult.depositAmounts[i]);
        }

        address[] memory weirollWallets = abi.decode(logs[logs.length - 1].data, (address[]));
        assertEq(weirollWallets.length, numDepositors);

        for (uint256 i = 0; i < numDepositors; i++) {
            // Check that deposit recipe is called
            vm.expectCall(USDC_POLYGON_ADDRESS, abi.encodeCall(ERC20.transfer, (address(0xbeef), bridgeResult.depositAmounts[i])));

            // Check that correct deposit recipe output state is reached
            vm.expectEmit(true, true, false, true, USDC_POLYGON_ADDRESS);
            emit ERC20.Transfer(weirollWallets[i], address(0xbeef), bridgeResult.depositAmounts[i]);
        }

        vm.startPrank(IP_ADDRESS);
        depositExecutor.executeDepositRecipes(bridgeResult.marketHash, weirollWallets);
        vm.stopPrank();

        for (uint256 i = 0; i < numDepositors; i++) {
            WeirollWallet weirollWalletForDepositor = WeirollWallet(payable(weirollWallets[i]));

            // Check wallet state is correct
            assertEq(weirollWalletForDepositor.executed(), true);
            // Check that deposit execution was done as specified by the deposit recipe
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletForDepositor)), 0);
        }
        // Check that 0xbeef received all funds on destination
        assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(0xbeef)), offerAmount);
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
            depositTokens,
            lzV2OFTs
        );

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
            recipeMarketHub.fillIPOffers(offerHash, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
            vm.stopPrank();

            result.depositAmounts[i] = depositLocker.marketHashToDepositorToAmountDeposited(result.marketHash, ap);
        }

        vm.startPrank(GREEN_LIGHTER_ADDRESS);
        depositLocker.setGreenLight(result.marketHash, true);
        vm.stopPrank();
        vm.warp(block.timestamp + depositLocker.RAGE_QUIT_PERIOD_DURATION());

        vm.recordLogs();
        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.startPrank(IP_ADDRESS);
        depositLocker.bridgeSingleTokens{ value: 5 ether }(result.marketHash, 1_000_000, result.depositors);
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
