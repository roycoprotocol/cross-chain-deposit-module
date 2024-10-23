// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the PredepositLocker contract and its dependencies
import { PredepositLocker, RecipeMarketHubBase, ERC20 } from "src/PredepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, WeirollWalletHelper, WeirollWallet, RewardStyle, Points } from "test/utils/RecipeMarketHubTestBase.sol";
import { PredepositExecutor } from "src/PredepositExecutor.sol";
import { IStargate } from "src/interfaces/IStargate.sol";
import { FixedPointMathLib } from "@solmate/utils/FixedPointMathLib.sol";
import { Vm } from "lib/forge-std/src/Vm.sol";
import { OFTComposeMsgCodec } from "src/libraries/OFTComposeMsgCodec.sol";
import { ClonesWithImmutableArgs } from "@clones-with-immutable-args/ClonesWithImmutableArgs.sol";

// Test deploying deposits via weiroll recipes post bridge
contract Test_PredepositExecutor is RecipeMarketHubTestBase {
    using FixedPointMathLib for uint256;

    address IP_ADDRESS;
    address AP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");
    string POLYGON_RPC_URL = vm.envString("POLYGON_RPC_URL");

    address constant POLYGON_LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint256 mainnetFork;
    uint256 polygonFork;

    function setUp() external {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        polygonFork = vm.createFork(POLYGON_RPC_URL);
    }

    function test_ExecutorOnBridge(uint256 offerAmount, uint256 numDepositors, uint256 unlockTimestamp) external {
        numDepositors = bound(numDepositors, 1, 309);
        offerAmount = bound(offerAmount, 1e6, type(uint48).max);
        unlockTimestamp = bound(unlockTimestamp, block.timestamp, type(uint128).max);

        // Simulate bridge
        (bytes32 sourceMarketHash, address[] memory depositors, uint256[] memory depositAmounts, bytes memory encodedPayload, bytes32 guid) =
            _bridgeDeposits(offerAmount, numDepositors);

        // Receive bridged funds on Polygon and execute recipes for depositor's wallet
        vm.selectFork(polygonFork);
        assertEq(vm.activeFork(), polygonFork);

        weirollImplementation = new WeirollWallet();
        WeirollWalletHelper walletHelper = new WeirollWalletHelper();

        ERC20[] memory predepositTokens = new ERC20[](1);
        address[] memory stargates = new address[](1);

        predepositTokens[0] = ERC20(USDC_POLYGON_ADDRESS); // USDC on Polygon Mainnet
        stargates[0] = STARGATE_USDC_POOL_POLYGON_ADDRESS; // Stargate USDC Pool on Polygon Mainnet

        PredepositExecutor predepositExecutor =
            new PredepositExecutor(OWNER_ADDRESS, address(weirollImplementation), POLYGON_LZ_ENDPOINT, predepositTokens, stargates);

        vm.startPrank(OWNER_ADDRESS);
        predepositExecutor.createPredepositCampaign(sourceMarketHash, IP_ADDRESS, ERC20(USDC_POLYGON_ADDRESS));
        vm.stopPrank();

        vm.startPrank(IP_ADDRESS);
        predepositExecutor.setPredepositCampaignLocktime(sourceMarketHash, unlockTimestamp);
        vm.stopPrank();

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE = _buildBurnDepositRecipe(address(walletHelper), USDC_POLYGON_ADDRESS);

        vm.startPrank(IP_ADDRESS);
        predepositExecutor.setDepositRecipe(sourceMarketHash, DEPOSIT_RECIPE.weirollCommands, DEPOSIT_RECIPE.weirollState);
        vm.stopPrank();

        // Fund the Executor (bridge simulation)
        deal(USDC_POLYGON_ADDRESS, address(predepositExecutor), offerAmount);

        for (uint256 i = 0; i < numDepositors; i++) {
            // Check that tokens being deposited into weiroll wallet
            vm.expectEmit(true, false, false, false, USDC_POLYGON_ADDRESS);
            emit ERC20.Transfer(address(predepositExecutor), address(0), depositAmounts[i]);

            // Check that deposit recipe is called
            vm.expectCall(USDC_POLYGON_ADDRESS, abi.encodeCall(ERC20.transfer, (address(0xbeef), depositAmounts[i])));

            // Check that correct deposit recipe output state is reached
            vm.expectEmit(false, true, false, false, USDC_POLYGON_ADDRESS);
            emit ERC20.Transfer(address(0), address(0xbeef), depositAmounts[i]);
        }

        vm.recordLogs();
        vm.startPrank(POLYGON_LZ_ENDPOINT);
        predepositExecutor.lzCompose(
            STARGATE_USDC_POOL_POLYGON_ADDRESS,
            guid,
            OFTComposeMsgCodec.encode(uint64(0), uint32(0), uint256(0), abi.encodePacked(bytes32(0), getSlice(188, encodedPayload))),
            address(0),
            bytes(abi.encode(0))
        );
        vm.stopPrank();

        // Check that all weiroll wallets were created and executed as expected
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < numDepositors; i++) {
            WeirollWallet weirollWalletForDepositor = WeirollWallet(payable(address(uint160(uint256(logs[i * 2].topics[2])))));

            // Check wallet state is correct
            assertEq(weirollWalletForDepositor.owner(), depositors[i]);
            assertEq(weirollWalletForDepositor.recipeMarketHub(), address(predepositExecutor));
            assertEq(weirollWalletForDepositor.amount(), depositAmounts[i]);
            assertEq(weirollWalletForDepositor.lockedUntil(), unlockTimestamp);
            assertEq(weirollWalletForDepositor.isForfeitable(), false);
            assertEq(weirollWalletForDepositor.marketHash(), sourceMarketHash);
            assertEq(weirollWalletForDepositor.executed(), true);
            assertEq(weirollWalletForDepositor.forfeited(), false);
            // Check that deposit was burned as specified by deposit recipe
            assertEq(ERC20(USDC_POLYGON_ADDRESS).balanceOf(address(weirollWalletForDepositor)), 0);
        }
    }

    function _bridgeDeposits(
        uint256 offerAmount,
        uint256 numDepositors
    )
        internal
        returns (bytes32 marketHash, address[] memory depositors, uint256[] memory depositAmounts, bytes memory encodedPayload, bytes32 guid)
    {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;
        vm.makePersistent(IP_ADDRESS);

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

        address payable[] memory depositorWallets = new address payable[](numDepositors);
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

        vm.recordLogs();
        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.startPrank(IP_ADDRESS);
        predepositLocker.bridge{ value: 5 ether }(marketHash, 1_000_000, depositorWallets);
        vm.stopPrank();

        // Get the encoded payload which will be passed in compose call on the destination chain
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (encodedPayload,,) = abi.decode(logs[logs.length - 3].data, (bytes, bytes, address));
        guid = logs[logs.length - 1].topics[1];
    }

    function getSlice(uint256 begin, bytes memory data) internal pure returns (bytes memory) {
        bytes memory a = new bytes(data.length - begin);
        for (uint256 i = 0; i < data.length - begin; i++) {
            a[i] = data[i + begin];
        }
        return a;
    }
}
