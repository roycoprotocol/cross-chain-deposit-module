// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import the DepositLocker contract and its dependencies
import { DepositLocker, RecipeMarketHubBase, ERC20, IWETH } from "../src/core/DepositLocker.sol";
import { RecipeMarketHubTestBase, RecipeMarketHubBase, RewardStyle, Points } from "./utils/RecipeMarketHubTestBase.sol";
import { IOFT } from "../src/interfaces/IOFT.sol";
import { WeirollWalletHelper } from "./utils/WeirollWalletHelper.sol";
import { MerkleTree } from "../../lib/openzeppelin-contracts/contracts/utils/structs/MerkleTree.sol";

// Test depositing and withdrawing to/from the DepositLocker through a Royco Market
// This will simulate the expected behaviour on the source chain of a Deposit Campaign
contract Test_DepositsAndWithdrawals_DepositLocker is RecipeMarketHubTestBase {
    using MerkleTree for MerkleTree.Bytes32PushTree;

    address IP_ADDRESS;
    address FRONTEND_FEE_RECIPIENT;

    DepositLocker depositLocker;
    WeirollWalletHelper walletHelper;

    uint256 frontendFee;
    bytes32 marketHash;
    bytes32 merkleMarketHash;

    MerkleTree.Bytes32PushTree merkleTree; // Merkle tree storing each deposit as a leaf.

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    uint256 mainnetFork;

    function setUp() external {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        walletHelper = new WeirollWalletHelper();

        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeMarketHubTests(protocolFee, minimumFrontendFee);

        IP_ADDRESS = ALICE_ADDRESS;
        FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

        ERC20[] memory depositTokens = new ERC20[](1);
        IOFT[] memory lzV2OFTs = new IOFT[](1);

        depositTokens[0] = ERC20(WETH_MAINNET_ADDRESS); // WETH on ETH Mainnet
        lzV2OFTs[0] = IOFT(STARGATE_POOL_NATIVE_MAINNET_ADDRESS); // Stargate native pool on ETH Mainnet

        depositLocker =
            new DepositLocker(OWNER_ADDRESS, 0, address(0xbeef), GREEN_LIGHTER_ADDRESS, recipeMarketHub, UNISWAP_V2_MAINNET_ROUTER_ADDRESS, lzV2OFTs);

        RecipeMarketHubBase.Recipe memory DEPOSIT_RECIPE =
            _buildDepositRecipe(DepositLocker.deposit.selector, address(walletHelper), WETH_MAINNET_ADDRESS, address(depositLocker));
        RecipeMarketHubBase.Recipe memory WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.withdraw.selector, address(depositLocker));

        frontendFee = recipeMarketHub.minimumFrontendFee();
        marketHash = recipeMarketHub.createMarket(WETH_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        DEPOSIT_RECIPE = _buildDepositRecipe(DepositLocker.merkleDeposit.selector, address(walletHelper), WETH_MAINNET_ADDRESS, address(depositLocker));
        WITHDRAWAL_RECIPE = _buildWithdrawalRecipe(DepositLocker.merkleWithdraw.selector, address(depositLocker));
        merkleMarketHash = recipeMarketHub.createMarket(WETH_MAINNET_ADDRESS, 30 days, frontendFee, DEPOSIT_RECIPE, WITHDRAWAL_RECIPE, RewardStyle.Forfeitable);

        merkleTree.setup(depositLocker.MERKLE_TREE_DEPTH(), depositLocker.NULL_LEAF());
    }

    function test_MerkleDeposits(uint256 offerAmount, uint256 numDepositors) external {
        // Bound the number of depositors and offer amount to prevent overflows and underflows
        numDepositors = bound(numDepositors, 1, depositLocker.MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE());
        offerAmount = bound(offerAmount, 1e6, ERC20(WETH_MAINNET_ADDRESS).totalSupply());

        // Check for dust removal
        vm.assume(_removeDust(offerAmount / numDepositors, 18, 6) > 0);

        // Initial balance check
        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), 0);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(merkleMarketHash, offerAmount, IP_ADDRESS);

        uint256 filledSoFar = 0; // Use fewer local variables

        // Loop through depositors
        for (uint256 i = 0; i < numDepositors; i++) {
            (filledSoFar,,) = testDeposit(offerHash, offerAmount, numDepositors, i, filledSoFar, true);
        }
    }

    function test_MerkleWithdrawals(uint256 offerAmount, uint256 numDepositors, uint256 numWithdrawals) external {
        // Bound the number of depositors and offer amount to prevent overflows and underflows
        numDepositors = bound(numDepositors, 1, depositLocker.MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE());
        offerAmount = bound(offerAmount, 1e6, ERC20(WETH_MAINNET_ADDRESS).totalSupply());
        numWithdrawals = bound(numWithdrawals, 1, numDepositors);

        // Check for dust removal
        vm.assume(_removeDust(offerAmount / numDepositors, 18, 6) > 0);

        // Initial balance check
        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), 0);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(merkleMarketHash, offerAmount, IP_ADDRESS);

        address[] memory aps = new address[](numDepositors);
        address[] memory depositorWallets = new address[](numDepositors);

        uint256 filledSoFar = 0; // Use fewer local variables

        // Loop through depositors
        for (uint256 i = 0; i < numDepositors; i++) {
            (uint256 filled, address ap, address wallet) = testDeposit(offerHash, offerAmount, numDepositors, i, filledSoFar, true);
            filledSoFar = filled;
            aps[i] = ap;
            depositorWallets[i] = wallet;
        }

        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), filledSoFar);

        uint256 withdrawnSoFar;

        vm.startPrank(OWNER_ADDRESS);
        depositLocker.haltMarket(merkleMarketHash);
        vm.stopPrank();

        for (uint256 i = 0; i < numWithdrawals; i++) {
            // Calculate the fill amount
            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = offerAmount - (fillAmount * (numDepositors - 1));
            }
            fillAmount = _removeDust(fillAmount, 18, 6);

            uint256 preWithdrawApTokenBalance = ERC20(WETH_MAINNET_ADDRESS).balanceOf(aps[i]);

            vm.startPrank(aps[i]);

            vm.expectEmit(true, true, false, true, WETH_MAINNET_ADDRESS);
            emit ERC20.Transfer(address(depositLocker), aps[i], fillAmount);

            vm.expectEmit(true, true, false, true, address(depositLocker));
            emit DepositLocker.MerkleWithdrawalMade(merkleMarketHash, aps[i], fillAmount);

            recipeMarketHub.forfeit(depositorWallets[i], true);
            vm.stopPrank();

            withdrawnSoFar += fillAmount;

            // (uint256 totalAmountDeposited,) = depositLocker.marketHashToMerkleDepositsInfo(marketHash);

            // assertEq(totalAmountDeposited, 0);

            assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(aps[i]), preWithdrawApTokenBalance + fillAmount);
            assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), filledSoFar - withdrawnSoFar);
        }
    }

    function test_IndividualDeposits(uint256 offerAmount, uint256 numDepositors) external {
        // Bound the number of depositors and offer amount to prevent overflows and underflows
        numDepositors = bound(numDepositors, 1, depositLocker.MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE());
        offerAmount = bound(offerAmount, 1e6, ERC20(WETH_MAINNET_ADDRESS).totalSupply());

        // Check for dust removal
        vm.assume(_removeDust(offerAmount / numDepositors, 18, 6) > 0);

        // Initial balance check
        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), 0);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        uint256 filledSoFar = 0; // Use fewer local variables

        // Loop through depositors
        for (uint256 i = 0; i < numDepositors; i++) {
            (filledSoFar,,) = testDeposit(offerHash, offerAmount, numDepositors, i, filledSoFar, false);
        }
    }

    function test_IndividualWithdrawals(uint256 offerAmount, uint256 numDepositors, uint256 numWithdrawals) external {
        vm.selectFork(mainnetFork);
        assertEq(vm.activeFork(), mainnetFork);

        // Bound the number of depositors and offer amount to prevent overflows and underflows
        numDepositors = bound(numDepositors, 1, depositLocker.MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE());
        offerAmount = bound(offerAmount, 1e6, ERC20(WETH_MAINNET_ADDRESS).totalSupply());
        numWithdrawals = bound(numWithdrawals, 1, numDepositors);

        // Check for dust removal
        vm.assume(_removeDust(offerAmount / numDepositors, 18, 6) > 0);

        // Initial balance check
        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), 0);

        // Create a fillable IP offer for points
        (bytes32 offerHash,) = createIPOffer_WithPoints(marketHash, offerAmount, IP_ADDRESS);

        address[] memory aps = new address[](numDepositors);
        address[] memory depositorWallets = new address[](numDepositors);

        uint256 filledSoFar = 0; // Use fewer local variables

        // Loop through depositors
        for (uint256 i = 0; i < numDepositors; i++) {
            (uint256 filled, address ap, address wallet) = testDeposit(offerHash, offerAmount, numDepositors, i, filledSoFar, false);
            filledSoFar = filled;
            aps[i] = ap;
            depositorWallets[i] = wallet;
        }

        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), filledSoFar);

        uint256 withdrawnSoFar;

        for (uint256 i = 0; i < numWithdrawals; i++) {
            // Calculate the fill amount
            uint256 fillAmount = offerAmount / numDepositors;
            if (i == (numDepositors - 1)) {
                fillAmount = offerAmount - (fillAmount * (numDepositors - 1));
            }
            fillAmount = _removeDust(fillAmount, 18, 6);

            uint256 preWithdrawApTokenBalance = ERC20(WETH_MAINNET_ADDRESS).balanceOf(aps[i]);

            vm.startPrank(aps[i]);

            vm.expectEmit(true, true, false, true, WETH_MAINNET_ADDRESS);
            emit ERC20.Transfer(address(depositLocker), aps[i], fillAmount);

            vm.expectEmit(true, true, false, true, address(depositLocker));
            emit DepositLocker.IndividualWithdrawalMade(marketHash, aps[i], fillAmount);

            recipeMarketHub.forfeit(depositorWallets[i], true);
            vm.stopPrank();

            withdrawnSoFar += fillAmount;

            (uint256 totalAmountDeposited,) = depositLocker.marketHashToDepositorToIndividualDepositorInfo(marketHash, aps[i]);
            (uint256 amountDeposited,) = depositLocker.depositorToWeirollWalletToWeirollWalletDepositInfo(aps[i], depositorWallets[i]);

            assertEq(totalAmountDeposited, 0);
            assertEq(amountDeposited, 0);

            assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(aps[i]), preWithdrawApTokenBalance + fillAmount);
            assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), filledSoFar - withdrawnSoFar);
        }
    }

    function testDeposit(
        bytes32 offerHash,
        uint256 offerAmount,
        uint256 numDepositors,
        uint256 i,
        uint256 filledSoFar,
        bool isMerkle
    )
        internal
        returns (uint256, address ap, address weirollWallet)
    {
        // Generate address for AP
        (ap,) = makeAddrAndKey(string(abi.encode(i)));

        // Calculate the fill amount
        uint256 fillAmount = offerAmount / numDepositors;
        if (i == (numDepositors - 1)) {
            fillAmount = offerAmount - (fillAmount * (numDepositors - 1));
        }
        fillAmount = _removeDust(fillAmount, 18, 6);

        // Update the filled amount
        filledSoFar += fillAmount;

        // Fund the AP and handle approval
        deal(WETH_MAINNET_ADDRESS, ap, fillAmount);
        vm.startPrank(ap);
        ERC20(WETH_MAINNET_ADDRESS).approve(address(recipeMarketHub), fillAmount);

        // Expect events
        vm.expectEmit(false, true, false, false, WETH_MAINNET_ADDRESS);
        emit ERC20.Transfer(address(0), address(depositLocker), fillAmount);

        if (isMerkle) {
            vm.expectEmit(true, true, true, false, address(depositLocker));
            emit DepositLocker.MerkleDepositMade(1, merkleMarketHash, ap, uint256(0), uint256(0), bytes32(0), uint256(0), bytes32(0));
        } else {
            vm.expectEmit(true, true, false, true, address(depositLocker));
            emit DepositLocker.IndividualDepositMade(marketHash, ap, fillAmount);
        }

        // Record the logs to capture Transfer events
        vm.recordLogs();
        bytes32[] memory ipOfferHashes = new bytes32[](1);
        ipOfferHashes[0] = offerHash;
        uint256[] memory fillAmounts = new uint256[](1);
        fillAmounts[0] = fillAmount;

        // AP Fills the offer (no funding vault)
        recipeMarketHub.fillIPOffers(ipOfferHashes, fillAmounts, address(0), FRONTEND_FEE_RECIPIENT);
        vm.stopPrank();

        // Extract the Weiroll wallet address
        weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[0].topics[2])));

        if (isMerkle) {
            // Generate the deposit leaf
            bytes32 depositLeaf = keccak256(abi.encodePacked(depositLocker.merkleDepositNonce() - 1, ap, fillAmount));
            // Add the deposit leaf to the Merkle Tree
            (, bytes32 updatedMerkleRoot) = merkleTree.push(depositLeaf);
            (, bytes32 marketMerkleRoot,,) = depositLocker.marketHashToMerkleDepositsInfo(merkleMarketHash);
            assertEq(updatedMerkleRoot, marketMerkleRoot);
        } else {
            // Assertions
            assertDepositorState(ap, weirollWallet, fillAmount, filledSoFar);
        }
        return (filledSoFar, ap, weirollWallet);
    }

    function assertDepositorState(address ap, address weirollWallet, uint256 fillAmount, uint256 filledSoFar) internal {
        (uint256 totalAmountDeposited,) = depositLocker.marketHashToDepositorToIndividualDepositorInfo(marketHash, ap);
        (uint256 amountDeposited,) = depositLocker.depositorToWeirollWalletToWeirollWalletDepositInfo(ap, weirollWallet);
        assertEq(totalAmountDeposited, fillAmount);
        assertEq(amountDeposited, fillAmount);
        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(address(depositLocker)), filledSoFar);
        assertEq(ERC20(WETH_MAINNET_ADDRESS).balanceOf(weirollWallet), 0);
    }
}
