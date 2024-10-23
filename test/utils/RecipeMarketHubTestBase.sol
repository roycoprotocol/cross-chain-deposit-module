// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@royco/test/mocks/MockRecipeMarketHub.sol";

import { MockERC20 } from "@royco/test/mocks/MockERC20.sol";
import { MockERC4626 } from "@royco/test/mocks/MockERC4626.sol";

import { RoycoTestBase } from "./RoycoTestBase.sol";
import { WeirollWalletHelper } from "test/utils/WeirollWalletHelper.sol";

contract RecipeMarketHubTestBase is RoycoTestBase {
    using FixedPointMathLib for uint256;

    // Fees set in RecipeMarketHub constructor
    uint256 initialProtocolFee;
    uint256 initialMinimumFrontendFee;

    function setUpRecipeMarketHubTests(uint256 _initialProtocolFee, uint256 _initialMinimumFrontendFee) public {
        setupBaseEnvironment();

        initialProtocolFee = _initialProtocolFee;
        initialMinimumFrontendFee = _initialMinimumFrontendFee;

        recipeMarketHub = new MockRecipeMarketHub(
            address(weirollImplementation),
            initialProtocolFee,
            initialMinimumFrontendFee,
            OWNER_ADDRESS, // fee claimant
            address(pointsFactory)
        );

        vm.startPrank(POINTS_FACTORY_OWNER_ADDRESS);
        pointsFactory.addRecipeMarketHub(address(recipeMarketHub));
        vm.stopPrank();
    }

    function createMarket(
        RecipeMarketHubBase.Recipe memory _depositRecipe,
        RecipeMarketHubBase.Recipe memory _withdrawRecipe
    )
        public
        returns (bytes32 marketHash)
    {
        // Generate random market parameters within valid constraints
        uint256 lockupTime = 1 hours + (uint256(keccak256(abi.encodePacked(block.timestamp))) % 29 days); // Lockup time between 1 hour and 30 days
        uint256 frontendFee = (uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender))) % 1e17) + initialMinimumFrontendFee;
        // Generate random reward style (valid values 0, 1, 2)
        RewardStyle rewardStyle = RewardStyle(uint8(uint256(keccak256(abi.encodePacked(block.timestamp))) % 3));
        // Create market
        marketHash = recipeMarketHub.createMarket(address(mockLiquidityToken), lockupTime, frontendFee, _depositRecipe, _withdrawRecipe, rewardStyle);
    }

    function createIPOffer_WithTokens(
        bytes32 _targetMarketHash,
        uint256 _quantity,
        address _ipAddress
    )
        public
        prankModifier(_ipAddress)
        returns (bytes32 offerHash)
    {
        address[] memory tokensOffered = new address[](1);
        tokensOffered[0] = address(mockIncentiveToken);
        uint256[] memory incentiveAmountsOffered = new uint256[](1);
        incentiveAmountsOffered[0] = 1000e18;

        mockIncentiveToken.mint(_ipAddress, 1000e18);
        mockIncentiveToken.approve(address(recipeMarketHub), 1000e18);

        offerHash = recipeMarketHub.createIPOffer(
            _targetMarketHash, // Referencing the created market
            _quantity, // Total input token amount
            block.timestamp + 30 days, // Expiry time
            tokensOffered, // Incentive tokens offered
            incentiveAmountsOffered // Incentive amounts offered
        );
    }

    function createIPOffer_WithTokens(
        bytes32 _targetMarketHash,
        uint256 _quantity,
        uint256 _expiry,
        address _ipAddress
    )
        public
        prankModifier(_ipAddress)
        returns (bytes32 offerHash)
    {
        address[] memory tokensOffered = new address[](1);
        tokensOffered[0] = address(mockIncentiveToken);
        uint256[] memory incentiveAmountsOffered = new uint256[](1);
        incentiveAmountsOffered[0] = 1000e18;

        mockIncentiveToken.mint(_ipAddress, 1000e18);
        mockIncentiveToken.approve(address(recipeMarketHub), 1000e18);

        offerHash = recipeMarketHub.createIPOffer(
            _targetMarketHash, // Referencing the created market
            _quantity, // Total input token amount
            _expiry, // Expiry time
            tokensOffered, // Incentive tokens offered
            incentiveAmountsOffered // Incentive amounts offered
        );
    }

    function createAPOffer_ForTokens(
        bytes32 _targetMarketHash,
        address _fundingVault,
        uint256 _quantity,
        address _apAddress
    )
        public
        prankModifier(_apAddress)
        returns (bytes32 offerHash, RecipeMarketHubBase.APOffer memory offer)
    {
        address[] memory tokensRequested = new address[](1);
        tokensRequested[0] = address(mockIncentiveToken);
        uint256[] memory tokenAmountsRequested = new uint256[](1);
        tokenAmountsRequested[0] = 1000e18;

        offerHash = recipeMarketHub.createAPOffer(
            _targetMarketHash, // Referencing the created market
            _fundingVault, // Address of funding vault
            _quantity, // Total input token amount
            30 days, // Expiry time
            tokensRequested, // Incentive tokens requested
            tokenAmountsRequested // Incentive amounts requested
        );

        offer = RecipeMarketHubBase.APOffer(
            recipeMarketHub.numAPOffers() - 1, _targetMarketHash, _apAddress, _fundingVault, _quantity, 30 days, tokensRequested, tokenAmountsRequested
        );
    }

    function createAPOffer_ForTokens(
        bytes32 _targetMarketHash,
        address _fundingVault,
        uint256 _quantity,
        uint256 _expiry,
        address _apAddress
    )
        public
        prankModifier(_apAddress)
        returns (bytes32 offerHash, RecipeMarketHubBase.APOffer memory offer)
    {
        address[] memory tokensRequested = new address[](1);
        tokensRequested[0] = address(mockIncentiveToken);
        uint256[] memory tokenAmountsRequested = new uint256[](1);
        tokenAmountsRequested[0] = 1000e18;

        offerHash = recipeMarketHub.createAPOffer(
            _targetMarketHash, // Referencing the created market
            _fundingVault, // Address of funding vault
            _quantity, // Total input token amount
            _expiry, // Expiry time
            tokensRequested, // Incentive tokens requested
            tokenAmountsRequested // Incentive amounts requested
        );

        offer = RecipeMarketHubBase.APOffer(
            recipeMarketHub.numAPOffers() - 1, _targetMarketHash, _apAddress, _fundingVault, _quantity, _expiry, tokensRequested, tokenAmountsRequested
        );
    }

    function createAPOffer_ForPoints(
        bytes32 _targetMarketHash,
        address _fundingVault,
        uint256 _quantity,
        address _apAddress,
        address _ipAddress
    )
        public
        returns (bytes32 offerHash, RecipeMarketHubBase.APOffer memory offer, Points points)
    {
        address[] memory tokensRequested = new address[](1);
        uint256[] memory tokenAmountsRequested = new uint256[](1);

        string memory name = "POINTS";
        string memory symbol = "PTS";

        vm.startPrank(_ipAddress);
        // Create a new Points program
        points = PointsFactory(recipeMarketHub.POINTS_FACTORY()).createPointsProgram(name, symbol, 18, _ipAddress);

        // Allow _ipAddress to mint points in the Points program
        points.addAllowedIP(_ipAddress);
        vm.stopPrank();

        // Add the Points program to the tokensOffered array
        tokensRequested[0] = address(points);
        tokenAmountsRequested[0] = 1000e18;

        vm.startPrank(_apAddress);
        offerHash = recipeMarketHub.createAPOffer(
            _targetMarketHash, // Referencing the created market
            _fundingVault, // Address of funding vault
            _quantity, // Total input token amount
            30 days, // Expiry time
            tokensRequested, // Incentive tokens requested
            tokenAmountsRequested // Incentive amounts requested
        );
        vm.stopPrank();
        offer = RecipeMarketHubBase.APOffer(
            recipeMarketHub.numAPOffers() - 1, _targetMarketHash, _apAddress, _fundingVault, _quantity, 30 days, tokensRequested, tokenAmountsRequested
        );
    }

    function createIPOffer_WithPoints(
        bytes32 _targetMarketHash,
        uint256 _quantity,
        address _ipAddress
    )
        public
        prankModifier(_ipAddress)
        returns (bytes32 offerHash, Points points)
    {
        address[] memory tokensOffered = new address[](1);
        uint256[] memory incentiveAmountsOffered = new uint256[](1);

        string memory name = "POINTS";
        string memory symbol = "PTS";

        // Create a new Points program
        points = PointsFactory(recipeMarketHub.POINTS_FACTORY()).createPointsProgram(name, symbol, 18, _ipAddress);

        // Allow _ipAddress to mint points in the Points program
        points.addAllowedIP(_ipAddress);

        // Add the Points program to the tokensOffered array
        tokensOffered[0] = address(points);
        incentiveAmountsOffered[0] = 1000e18;

        offerHash = recipeMarketHub.createIPOffer(
            _targetMarketHash, // Referencing the created market
            _quantity, // Total input token amount
            block.timestamp + 30 days, // Expiry time
            tokensOffered, // Incentive tokens offered
            incentiveAmountsOffered // Incentive amounts offered
        );
    }

    function calculateIPOfferExpectedIncentiveAndFrontendFee(
        bytes32 offerHash,
        uint256 offerAmount,
        uint256 fillAmount,
        address tokenOffered
    )
        internal
        view
        returns (uint256 fillPercentage, uint256 protocolFeeAmount, uint256 frontendFeeAmount, uint256 incentiveAmount)
    {
        fillPercentage = fillAmount.divWadDown(offerAmount);
        // Fees are taken as a percentage of the promised amounts
        protocolFeeAmount = recipeMarketHub.getIncentiveToProtocolFeeAmountForIPOffer(offerHash, tokenOffered).mulWadDown(fillPercentage);
        frontendFeeAmount = recipeMarketHub.getIncentiveToFrontendFeeAmountForIPOffer(offerHash, tokenOffered).mulWadDown(fillPercentage);
        incentiveAmount = recipeMarketHub.getIncentiveAmountsOfferedForIPOffer(offerHash, tokenOffered).mulWadDown(fillPercentage);
    }

    function calculateAPOfferExpectedIncentiveAndFrontendFee(
        uint256 protocolFee,
        uint256 frontendFee,
        uint256 offerAmount,
        uint256 fillAmount,
        uint256 tokenAmountRequested
    )
        internal
        pure
        returns (uint256 fillPercentage, uint256 frontendFeeAmount, uint256 protocolFeeAmount, uint256 incentiveAmount)
    {
        fillPercentage = fillAmount.divWadDown(offerAmount);
        incentiveAmount = tokenAmountRequested.mulWadDown(fillPercentage);
        protocolFeeAmount = incentiveAmount.mulWadDown(protocolFee);
        frontendFeeAmount = incentiveAmount.mulWadDown(frontendFee);
    }

    // Get fill amount using Weiroll Helper -> Approve fill amount -> Call Deposit
    function _buildDepositRecipe(
        bytes4 _depositSelector,
        address _helper,
        address _tokenAddress,
        address _predepositLocker
    )
        internal
        pure
        returns (RecipeMarketHubBase.Recipe memory)
    {
        bytes32[] memory commands = new bytes32[](3);
        bytes[] memory state = new bytes[](2);

        state[0] = abi.encode(_predepositLocker);

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

        // APPROVE Predeposit Locker to spend tokens

        // CALL
        f = uint8(0x01);

        // Input list: Args at state index 0 (address) and args at state index 1 (fill amount)
        inputData = hex"0001ffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = 0xff;

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[1] = (bytes32(abi.encodePacked(ERC20.approve.selector, f, inputData, o, _tokenAddress)));

        // CALL DEPOSIT() in Predeposit Locker
        f = uint8(0x01);

        // Input list: No arguments (END_OF_ARGS = 0xff)
        inputData = hex"ffffffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = uint8(0xff);

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[2] = (bytes32(abi.encodePacked(_depositSelector, f, inputData, o, _predepositLocker)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }

    function _buildWithdrawalRecipe(bytes4 _withdrawalSelector, address _predepositLocker) internal pure returns (RecipeMarketHubBase.Recipe memory) {
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
        commands[0] = (bytes32(abi.encodePacked(_withdrawalSelector, f, inputData, o, _predepositLocker)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }

    // Burn tokens that were deposited
    function _buildBurnDepositRecipe(address _helper, address _tokenAddress) internal pure returns (RecipeMarketHubBase.Recipe memory) {
        bytes32[] memory commands = new bytes32[](2);
        bytes[] memory state = new bytes[](2);

        state[0] = abi.encode(address(0xbeef));

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

        // Send tokens to burn address

        // CALL
        f = uint8(0x01);

        // Input list: Args at state index 0 (fill amount) and args at state index 1 (0 address)
        inputData = hex"0001ffffffff";

        // Output specifier (fixed length return value stored at index 0 of the output array)
        // 0xff ignores the output if any
        o = 0xff;

        // Encode args and add command to RecipeMarketHubBase.Recipe
        commands[1] = (bytes32(abi.encodePacked(ERC20.transfer.selector, f, inputData, o, _tokenAddress)));

        return RecipeMarketHubBase.Recipe(commands, state);
    }
}
