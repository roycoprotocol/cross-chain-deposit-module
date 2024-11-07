// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { RecipeMarketHubBase, ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt } from "src/interfaces/IOFT.sol";
import { IWETH } from "src/interfaces/IWETH.sol";
import { OptionsBuilder } from "src/libraries/OptionsBuilder.sol";
import { DualToken } from "src/periphery/DualToken.sol";
import { DualTokenFactory } from "src/periphery/DualTokenFactory.sol";
import { DepositType, DepositPayloadLib } from "src/libraries/DepositPayloadLib.sol";
import { IUniswapV2Router01 } from "@uniswap-v2/periphery/contracts/interfaces/IUniswapV2Router01.sol";
import { IUniswapV2Pair } from "@uniswap-v2/core/contracts/interfaces/IUniswapV2Pair.sol";

/// @title DepositLocker
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A singleton contract for managing deposits for the destination chain on the source chain.
/// @notice Facilitates deposits, withdrawals, and bridging deposits for all deposit markets.
contract DepositLocker is Ownable2Step, ReentrancyGuardTransient {
    using SafeTransferLib for ERC20;
    using OptionsBuilder for bytes;
    using DepositPayloadLib for bytes;

    /*//////////////////////////////////////////////////////////////
                                   Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice The limit for how many depositors can be bridged in a single transaction
    uint256 public constant MAX_DEPOSITORS_PER_BRIDGE = 100;

    /*//////////////////////////////////////////////////////////////
                                    State
    //////////////////////////////////////////////////////////////*/

    /// @notice The RecipeMarketHub keeping track of all Royco markets and offers.
    RecipeMarketHubBase public immutable RECIPE_MARKET_HUB;

    /// @notice The DualToken Factory used to create new DualTokens.
    DualTokenFactory public immutable DUAL_TOKEN_FACTORY;

    /// @notice The wrapped native asset token on the source chain.
    IWETH public immutable WRAPPED_NATIVE_ASSET_TOKEN;

    /// @notice The Uniswap V2 router on the source chain.
    IUniswapV2Router01 public immutable UNISWAP_V2_ROUTER;

    /// @notice The LayerZero endpoint ID for the destination chain.
    uint32 public dstChainLzEid;

    /// @notice Mapping of an ERC20 token to its corresponding LayerZero OFT.
    /// @dev Must implement the IOFT interface.
    mapping(ERC20 => IOFT) public tokenToLzV2OFT;

    /// @notice Address of the DepositExecutor on the destination chain.
    address public depositExecutor;

    /// @notice Mapping from market hash to the multisig address between the market's IP and the destination chain.
    mapping(bytes32 => address) public marketHashToMultisig;

    /// @notice Mapping from market hash to depositor's address to the total amount they deposited.
    mapping(bytes32 => mapping(address => uint256)) public marketHashToDepositorToAmountDeposited;

    /// @notice Mapping from market hash to depositor's address to their Weiroll Wallets.
    mapping(bytes32 => mapping(address => address[])) public marketHashToDepositorToWeirollWallets;

    /// @notice Mapping from depositor's address to Weiroll Wallet to amount deposited by that Weiroll Wallet.
    mapping(address => mapping(address => uint256)) public depositorToWeirollWalletToAmount;

    /// @notice Mapping from market hash to green light status for bridging funds.
    mapping(bytes32 => bool) public marketHashToGreenLight;

    /// @notice Used to keep track of DUAL_TOKEN bridges.
    /// @notice A DUAL_TOKEN bridge will result in 2 OFT bridges (each with the same nonce).
    uint256 public nonce;

    /*//////////////////////////////////////////////////////////////
                            Structures
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct to hold parameters for bridging dual tokens.
    struct DualTokenBridgeParams {
        bytes32 marketHash;
        uint128 executorGasLimit;
        ERC20 tokenA;
        ERC20 tokenB;
        uint256 tokenA_TotalAmountToBridge;
        uint256 tokenB_TotalAmountToBridge;
        bytes tokenA_ComposeMsg;
        bytes tokenB_ComposeMsg;
    }

    /// @notice Struct to hold parameters for processing LP token depositors.
    struct LpTokenDepositorParams {
        bytes32 marketHash;
        address depositor;
        uint256 lp_TotalAmountToBridge;
        uint256 tokenA_TotalAmountReceivedOnBurn;
        uint256 tokenB_TotalAmountReceivedOnBurn;
        uint256 tokenA_DecimalConversionRate;
        uint256 tokenB_DecimalConversionRate;
    }

    /// @notice Struct to hold total amounts for Token A and Token B.
    struct Totals {
        uint256 tokenA;
        uint256 tokenB;
    }

    /*//////////////////////////////////////////////////////////////
                            Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits funds.
    event UserDeposited(bytes32 indexed marketHash, address indexed depositor, uint256 amountDeposited);

    /// @notice Emitted when a user withdraws funds.
    event UserWithdrawn(bytes32 indexed marketHash, address indexed depositor, uint256 amountWithdrawn);

    /// @notice Emitted when single tokens are bridged to the destination chain.
    event SingleTokenBridgeToDestinationChain(bytes32 indexed marketHash, bytes32 lz_guid, uint64 lz_nonce, uint256 amountBridged);

    /// @notice Emitted when dual tokens are bridged to the destination chain.
    event DualTokenBridgeToDestinationChain(
        bytes32 indexed marketHash,
        uint256 indexed dt_bridge_nonce,
        bytes32 lz_tokenA_guid,
        uint64 lz_tokenA_nonce,
        uint256 lz_tokenA_AmountBridged,
        bytes32 lz_tokenB_guid,
        uint64 lz_tokenB_nonce,
        uint256 lz_tokenB_AmountBridged
    );

    /// @notice Error emitted when setting a lzV2OFT for a token that doesn't match the OApp's underlying token
    error InvalidLzV2OFTForToken();

    /// @notice Error emitted when calling withdraw with nothing deposited
    error NothingToWithdraw();

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when green light is not given for bridging.
    error GreenLightNotGiven();

    /// @notice Error emitted when the caller is not the authorized multisig for the market.
    error UnauthorizedMultisigForThisMarket();

    /// @notice Error emitted when the deposit amount is too precise to bridge based on the shared decimals of the OFT
    error DepositAmountIsTooPrecise();

    /// @notice Error emitted when attempting to bridge more depositors than the bridge limit
    error DepositorsPerBridgeLimitExceeded();

    /// @notice Error emitted when attempting to bridge an amount greater than the bridge limit
    error BridgeAmountLimitExceeded();

    /// @notice Error emitted when attempting to bridge 0 depositors.
    error MustBridgeAtLeastOneDepositor();

    /// @notice Error emitted when insufficient msg.value is provided for the bridge fee.
    error InsufficientValueForBridgeFee();

    /// @notice Error emitted when bridging all the specified deposits fails.
    error FailedToBridgeAllDeposits();

    /*//////////////////////////////////////////////////////////////
                                       Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the authorized multisig for the market.
    modifier onlyMultisig(bytes32 _marketHash) {
        require(marketHashToMultisig[_marketHash] == msg.sender, UnauthorizedMultisigForThisMarket());
        _;
    }

    /// @dev Modifier to check if green light is given for bridging.
    modifier greenLightGiven(bytes32 _marketHash) {
        require(marketHashToGreenLight[_marketHash], GreenLightNotGiven());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the DepositLocker Contract.
     * @param _owner The address of the owner of the contract.
     * @param _dstChainLzEid The destination LayerZero endpoint ID for the destination chain.
     * @param _depositExecutor The address of the DepositExecutor on the destination chain.
     * @param _recipeMarketHub The address of the recipe market hub used to create markets on the source chain.
     * @param _wrapped_native_asset_token The address of the wrapped native asset token on the source chain.
     * @param _uniswap_v2_router The address of the Uniswap V2 router on the source chain.
     * @param _depositTokens The tokens to bridge to the destination chain from the source chain.
     * @param _lzV2OFTs The corresponding LayerZero OApp instances for each deposit token on the source chain.
     */
    constructor(
        address _owner,
        uint32 _dstChainLzEid,
        address _depositExecutor,
        RecipeMarketHubBase _recipeMarketHub,
        IWETH _wrapped_native_asset_token,
        IUniswapV2Router01 _uniswap_v2_router,
        ERC20[] memory _depositTokens,
        IOFT[] memory _lzV2OFTs
    )
        Ownable(_owner)
    {
        // Check that each token that will be bridged has a corresponding LZOApp instance
        require(_depositTokens.length == _lzV2OFTs.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _depositTokens.length; ++i) {
            // Get the underlying token for this OFT
            address underlyingToken = _lzV2OFTs[i].token();
            // Check that the underlying token is the specified token or the chain's native asset
            require(underlyingToken == address(_depositTokens[i]) || underlyingToken == address(0), InvalidLzV2OFTForToken());
            tokenToLzV2OFT[_depositTokens[i]] = _lzV2OFTs[i];
        }

        RECIPE_MARKET_HUB = _recipeMarketHub;
        DUAL_TOKEN_FACTORY = new DualTokenFactory(); // Create the DualToken factory
        WRAPPED_NATIVE_ASSET_TOKEN = _wrapped_native_asset_token;
        UNISWAP_V2_ROUTER = _uniswap_v2_router;
        dstChainLzEid = _dstChainLzEid;
        depositExecutor = _depositExecutor;
    }

    /*//////////////////////////////////////////////////////////////
                                External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Called by the deposit script from the depositor's Weiroll wallet.
     */
    function deposit() external nonReentrant {
        // Get Weiroll Wallet's market hash, depositor/owner/AP, and amount deposited
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        bytes32 targetMarketHash = wallet.marketHash();
        address depositor = wallet.owner();
        uint256 amountDeposited = wallet.amount();

        // Get the token to deposit for this market
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);

        if (!DUAL_TOKEN_FACTORY.isDualToken(address(marketInputToken))) {
            // Check that the deposit amount is less or equally as precise as specified by the shared decimals of the OFT
            bool depositAmountHasValidPrecision =
                amountDeposited % (10 ** (marketInputToken.decimals() - tokenToLzV2OFT[marketInputToken].sharedDecimals())) == 0;
            require(depositAmountHasValidPrecision, DepositAmountIsTooPrecise());
        }

        // Transfer the deposit amount from the Weiroll Wallet to the DepositLocker
        marketInputToken.safeTransferFrom(msg.sender, address(this), amountDeposited);

        // Account for deposit
        marketHashToDepositorToAmountDeposited[targetMarketHash][depositor] += amountDeposited;
        marketHashToDepositorToWeirollWallets[targetMarketHash][depositor].push(msg.sender);
        depositorToWeirollWalletToAmount[depositor][msg.sender] = amountDeposited;

        // Emit deposit event
        emit UserDeposited(targetMarketHash, depositor, amountDeposited);
    }

    /**
     * @notice Called by the withdraw script from the depositor's Weiroll wallet.
     */
    function withdraw() external nonReentrant {
        // Get Weiroll Wallet's market hash and depositor/owner/AP
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        bytes32 targetMarketHash = wallet.marketHash();
        address depositor = wallet.owner();

        // Get amount to withdraw for this Weiroll Wallet
        uint256 amountToWithdraw = depositorToWeirollWalletToAmount[depositor][msg.sender];
        require(amountToWithdraw > 0, NothingToWithdraw());
        // Account for the withdrawal
        marketHashToDepositorToAmountDeposited[targetMarketHash][depositor] -= amountToWithdraw;
        delete depositorToWeirollWalletToAmount[depositor][msg.sender];

        // Transfer back the amount deposited directly to the AP
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);
        marketInputToken.safeTransfer(depositor, amountToWithdraw);

        // Emit withdrawal event
        emit UserWithdrawn(targetMarketHash, depositor, amountToWithdraw);
    }

    /**
     * @notice Bridges depositors in single token markets from the source chain to the destination chain.
     * @dev NOTE: Be generous with the _executorGasLimit to prevent reversion on the destination chain.
     * @dev Green light must be given before calling.
     * @param _marketHash The hash of the market to bridge tokens for.
     * @param _executorGasLimit The gas limit of the executor on the destination chain.
     * @param _depositors The addresses of the depositors (APs) to bridge
     */
    function bridgeSingleToken(
        bytes32 _marketHash,
        uint128 _executorGasLimit,
        address[] calldata _depositors
    )
        external
        payable
        greenLightGiven(_marketHash)
        nonReentrant
    {
        require(_depositors.length <= MAX_DEPOSITORS_PER_BRIDGE, DepositorsPerBridgeLimitExceeded());

        /*
        Bridge Payload Structure:
            Per Payload (33 bytes):
                - DepositType: uint8 (1 byte) - SINGLE_TOKEN
                - marketHash: bytes32 (32 bytes)
            Per Depositor (32 bytes):
                - Depositor / AP address: address (20 bytes)
                - Amount Deposited: uint96 (12 bytes)
        */

        // Initialize compose message - first 33 bytes are BRIDGE_TYPE and market hash
        bytes memory composeMsg = DepositPayloadLib.initSingleTokenComposeMsg(_marketHash);

        // Keep track of total amount of deposits to bridge
        uint256 totalAmountToBridge;

        for (uint256 i = 0; i < _depositors.length; ++i) {
            uint256 depositAmount;
            // Process depositor and update the compose message
            (depositAmount, composeMsg) = _processSingleTokenDepositor(_marketHash, _depositors[i], composeMsg);
            totalAmountToBridge += depositAmount;
        }

        // Ensure that at least one depositor was included in the bridge payload
        require(totalAmountToBridge > 0, MustBridgeAtLeastOneDepositor());

        // Prepare SendParam for bridging
        SendParam memory sendParam = SendParam({
            dstEid: dstChainLzEid,
            to: _addressToBytes32(depositExecutor),
            amountLD: totalAmountToBridge,
            minAmountLD: totalAmountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _executorGasLimit, 0),
            composeMsg: composeMsg,
            oftCmd: ""
        });

        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        // Bridge the tokens with the marshaled parameters
        MessagingReceipt memory messageReceipt = _bridgeTokens(marketInputToken, 0, sendParam);
        uint256 bridgingFee = messageReceipt.fee.nativeFee;

        // Refund excess value sent with the transaction
        if (msg.value > bridgingFee) {
            payable(msg.sender).transfer(msg.value - bridgingFee);
        }

        // Emit event to keep track of bridged deposits
        emit SingleTokenBridgeToDestinationChain(_marketHash, messageReceipt.guid, messageReceipt.nonce, totalAmountToBridge);
    }

    /**
     * @notice Bridges depositors in dual token markets from the source chain to the destination chain.
     * @dev NOTE: Be generous with the _executorGasLimit to prevent reversion on the destination chain.
     * @dev Green light must be given before calling.
     * @param _marketHash The hash of the market to bridge tokens for.
     * @param _executorGasLimit The gas limit of the executor on the destination chain.
     * @param _depositors The addresses of the depositors (APs) to bridge
     */
    function bridgeDualToken(
        bytes32 _marketHash,
        uint128 _executorGasLimit,
        address[] calldata _depositors
    )
        external
        payable
        greenLightGiven(_marketHash)
        nonReentrant
    {
        require(_depositors.length <= MAX_DEPOSITORS_PER_BRIDGE, DepositorsPerBridgeLimitExceeded());

        /*
        Bridge Payload Structure:
            Per Payload (65 bytes):
                - DepositType: uint8 (1 byte) - DUAL_TOKEN
                - marketHash: bytes32 (32 bytes)
                - nonce: uint256 (32 bytes)
            Per Depositor (32 bytes):
                - Depositor / AP address: address (20 bytes)
                - Amount Deposited: uint96 (12 bytes)
        */

        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        // Extract DualToken constituent tokens and amounts
        DualToken dualToken = DualToken(address(marketInputToken));
        ERC20 tokenA = dualToken.tokenA();
        ERC20 tokenB = dualToken.tokenB();
        uint256 amountOfTokenAPerDT = dualToken.amountOfTokenAPerDT();
        uint256 amountOfTokenBPerDT = dualToken.amountOfTokenBPerDT();

        // Initialize compose messages for both tokens
        bytes memory tokenA_ComposeMsg = DepositPayloadLib.initDualTokenComposeMsg(_marketHash, nonce);
        bytes memory tokenB_ComposeMsg = DepositPayloadLib.initDualTokenComposeMsg(_marketHash, nonce);

        // Keep track of total amount of deposits to bridge
        uint256 dt_TotalDepositsInBatch = 0;
        uint256 tokenA_TotalAmountToBridge = 0;
        uint256 tokenB_TotalAmountToBridge = 0;

        for (uint256 i = 0; i < _depositors.length; ++i) {
            uint256 dt_depositAmount;
            uint256 tokenA_DepositAmount;
            uint256 tokenB_DepositAmount;

            // Process the depositor and update the compose messages
            (dt_depositAmount, tokenA_DepositAmount, tokenB_DepositAmount, tokenA_ComposeMsg, tokenB_ComposeMsg) =
                _processDualTokenDepositor(_marketHash, _depositors[i], amountOfTokenAPerDT, amountOfTokenBPerDT, tokenA_ComposeMsg, tokenB_ComposeMsg);

            // Update total amounts
            dt_TotalDepositsInBatch += dt_depositAmount;
            tokenA_TotalAmountToBridge += tokenA_DepositAmount;
            tokenB_TotalAmountToBridge += tokenB_DepositAmount;
        }

        // Ensure that at least one depositor was included in the bridge payload
        require(tokenA_TotalAmountToBridge > 0 && tokenB_TotalAmountToBridge > 0, MustBridgeAtLeastOneDepositor());

        // Burn the dual tokens to receive the constituents in the DepositLocker
        dualToken.burn(dt_TotalDepositsInBatch);

        // Create bridge parameters
        DualTokenBridgeParams memory bridgeParams = DualTokenBridgeParams({
            marketHash: _marketHash,
            executorGasLimit: _executorGasLimit,
            tokenA: tokenA,
            tokenB: tokenB,
            tokenA_TotalAmountToBridge: tokenA_TotalAmountToBridge,
            tokenB_TotalAmountToBridge: tokenB_TotalAmountToBridge,
            tokenA_ComposeMsg: tokenA_ComposeMsg,
            tokenB_ComposeMsg: tokenB_ComposeMsg
        });

        // Execute 2 consecutive bridges for each constituent token
        _bridgeDualTokens(bridgeParams);
    }

    /**
     * @notice Bridges depositors in Uniswap V2 LP token markets from the source chain to the destination chain.
     * @dev Handles bridge precision by adjusting amounts to acceptable precision and refunding any dust to depositors.
     * @dev Green light must be given before calling.
     * @param _marketHash The hash of the market to bridge tokens for.
     * @param _executorGasLimit The gas limit of the executor on the destination chain.
     * @param _minAmountOfTokenAToBridge The minimum amount of Token A to receive from removing liquidity.
     * @param _minAmountOfTokenBToBridge The minimum amount of Token B to receive from removing liquidity.
     * @param _depositors The addresses of the depositors (APs) to bridge.
     */
    function bridgeLpToken(
        bytes32 _marketHash,
        uint128 _executorGasLimit,
        uint96 _minAmountOfTokenAToBridge,
        uint96 _minAmountOfTokenBToBridge,
        address[] calldata _depositors
    )
        external
        payable
        greenLightGiven(_marketHash)
        nonReentrant
    {
        require(_depositors.length <= MAX_DEPOSITORS_PER_BRIDGE, DepositorsPerBridgeLimitExceeded());

        /*
        Bridge Payload Structure:
            Per Payload (65 bytes):
                - DepositType: uint8 (1 byte) - DUAL_TOKEN
                - marketHash: bytes32 (32 bytes)
                - nonce: uint256 (32 bytes)
            Per Depositor (32 bytes):
                - Depositor / AP address: address (20 bytes)
                - Amount Deposited: uint96 (12 bytes)
        */

        // Sum up total LP token deposits for this batch
        uint256 lp_TotalDepositsInBatch = 0;
        for (uint256 i = 0; i < _depositors.length; ++i) {
            lp_TotalDepositsInBatch += marketHashToDepositorToAmountDeposited[_marketHash][_depositors[i]];
        }

        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        // Initialize the Uniswap V2 pair from the market's input token
        IUniswapV2Pair uniV2Pair = IUniswapV2Pair(address(marketInputToken));
        // Approve the LP tokens to be spent by the Uniswap V2 Router
        marketInputToken.safeApprove(address(UNISWAP_V2_ROUTER), lp_TotalDepositsInBatch);

        // Get the individual Pool Tokens in the Uniswap V2 Pair
        ERC20 tokenA = ERC20(uniV2Pair.token0());
        ERC20 tokenB = ERC20(uniV2Pair.token1());

        // Burn the LP tokens and retrieve the pair's underlying tokens
        (uint256 tokenA_AmountReceivedOnBurn, uint256 tokenB_AmountReceivedOnBurn) = UNISWAP_V2_ROUTER.removeLiquidity(
            address(tokenA), address(tokenB), lp_TotalDepositsInBatch, _minAmountOfTokenAToBridge, _minAmountOfTokenBToBridge, address(this), block.timestamp
        );

        require(tokenA_AmountReceivedOnBurn <= type(uint96).max && tokenB_AmountReceivedOnBurn <= type(uint96).max, BridgeAmountLimitExceeded());

        uint256 tokenA_DecimalConversionRate = 10 ** (tokenA.decimals() - tokenToLzV2OFT[tokenA].sharedDecimals());
        uint256 tokenB_DecimalConversionRate = 10 ** (tokenB.decimals() - tokenToLzV2OFT[tokenB].sharedDecimals());

        // Initialize compose messages for both tokens
        bytes memory tokenA_ComposeMsg = DepositPayloadLib.initDualTokenComposeMsg(_marketHash, nonce);
        bytes memory tokenB_ComposeMsg = DepositPayloadLib.initDualTokenComposeMsg(_marketHash, nonce);

        // Initialize totals
        Totals memory totals;

        // Marshal the bridge payload for each token's bridge
        for (uint256 i = 0; i < _depositors.length; ++i) {
            // Create params struct
            LpTokenDepositorParams memory params = LpTokenDepositorParams({
                marketHash: _marketHash,
                depositor: _depositors[i],
                lp_TotalAmountToBridge: lp_TotalDepositsInBatch,
                tokenA_TotalAmountReceivedOnBurn: tokenA_AmountReceivedOnBurn,
                tokenB_TotalAmountReceivedOnBurn: tokenB_AmountReceivedOnBurn,
                tokenA_DecimalConversionRate: tokenA_DecimalConversionRate,
                tokenB_DecimalConversionRate: tokenB_DecimalConversionRate
            });

            // Process the depositor and update the compose messages and totals
            (tokenA_ComposeMsg, tokenB_ComposeMsg) = _processLpTokenDepositor(params, tokenA, tokenB, tokenA_ComposeMsg, tokenB_ComposeMsg, totals);
        }

        // Create bridge parameters
        DualTokenBridgeParams memory bridgeParams = DualTokenBridgeParams({
            marketHash: _marketHash,
            executorGasLimit: _executorGasLimit,
            tokenA: tokenA,
            tokenB: tokenB,
            tokenA_TotalAmountToBridge: totals.tokenA,
            tokenB_TotalAmountToBridge: totals.tokenB,
            tokenA_ComposeMsg: tokenA_ComposeMsg,
            tokenB_ComposeMsg: tokenB_ComposeMsg
        });

        // Execute 2 consecutive bridges for each constituent token
        _bridgeDualTokens(bridgeParams);
    }

    /*//////////////////////////////////////////////////////////////
                          Internal Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Bridges two tokens to the destination chain using LayerZero's OFT.
     * @dev Handles the bridging of Token A and Token B, fee management, and event emission.
     * @param params The parameters required for bridging dual tokens.
     */
    function _bridgeDualTokens(DualTokenBridgeParams memory params) internal {
        uint256 totalBridgingFee = 0;

        // Prepare SendParam for bridging Token A
        SendParam memory sendParamA = SendParam({
            dstEid: dstChainLzEid,
            to: _addressToBytes32(depositExecutor),
            amountLD: params.tokenA_TotalAmountToBridge,
            minAmountLD: params.tokenA_TotalAmountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, params.executorGasLimit, 0),
            composeMsg: params.tokenA_ComposeMsg,
            oftCmd: ""
        });

        // Bridge Token A
        MessagingReceipt memory tokenA_MessageReceipt = _bridgeTokens(params.tokenA, 0, sendParamA);
        totalBridgingFee += tokenA_MessageReceipt.fee.nativeFee;

        // Prepare SendParam for bridging Token B
        SendParam memory sendParamB = SendParam({
            dstEid: dstChainLzEid,
            to: _addressToBytes32(depositExecutor),
            amountLD: params.tokenB_TotalAmountToBridge,
            minAmountLD: params.tokenB_TotalAmountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, params.executorGasLimit, 0),
            composeMsg: params.tokenB_ComposeMsg,
            oftCmd: ""
        });

        // Bridge Token B
        MessagingReceipt memory tokenB_MessageReceipt = _bridgeTokens(params.tokenB, totalBridgingFee, sendParamB);
        totalBridgingFee += tokenB_MessageReceipt.fee.nativeFee;

        // Refund excess value sent with the transaction
        if (msg.value > totalBridgingFee) {
            payable(msg.sender).transfer(msg.value - totalBridgingFee);
        }

        // Emit event to keep track of bridged deposits
        emit DualTokenBridgeToDestinationChain(
            params.marketHash,
            nonce++,
            tokenA_MessageReceipt.guid,
            tokenA_MessageReceipt.nonce,
            params.tokenA_TotalAmountToBridge,
            tokenB_MessageReceipt.guid,
            tokenB_MessageReceipt.nonce,
            params.tokenB_TotalAmountToBridge
        );
    }

    /**
     * @notice Processes a single token depositor by updating the compose message and clearing depositor data.
     * @dev Updates the compose message with the depositor's information if the deposit amount is valid.
     * @param _marketHash The hash of the market to process.
     * @param _depositor The address of the depositor.
     * @param _composeMsg The current compose message to be updated.
     */
    function _processSingleTokenDepositor(bytes32 _marketHash, address _depositor, bytes memory _composeMsg) internal returns (uint256, bytes memory) {
        // Get amount deposited by the depositor (AP)
        uint256 depositAmount = marketHashToDepositorToAmountDeposited[_marketHash][_depositor];
        if (depositAmount == 0 || depositAmount > type(uint96).max) {
            return (depositAmount, _composeMsg); // Skip if no deposit or deposit amount exceeds limit
        }

        // Delete all Weiroll Wallet state and deposit amounts associated with this depositor
        _clearDepositorData(_marketHash, _depositor);

        // Add depositor to the compose message
        _composeMsg = _composeMsg.writeDepositor(_depositor, uint96(depositAmount));

        return (depositAmount, _composeMsg);
    }

    /**
     * @notice Processes a dual token depositor by updating compose messages and clearing depositor data.
     * @dev Calculates the amount of each constituent token and updates the compose messages accordingly.
     * @param _marketHash The hash of the market to process.
     * @param _depositor The address of the depositor.
     * @param _amountOfTokenAPerDT The amount of Token A per dual token.
     * @param _amountOfTokenBPerDT The amount of Token B per dual token.
     * @param _tokenA_ComposeMsg The current compose message for Token A to be updated.
     * @param _tokenB_ComposeMsg The current compose message for Token B to be updated.
     */
    function _processDualTokenDepositor(
        bytes32 _marketHash,
        address _depositor,
        uint256 _amountOfTokenAPerDT,
        uint256 _amountOfTokenBPerDT,
        bytes memory _tokenA_ComposeMsg,
        bytes memory _tokenB_ComposeMsg
    )
        internal
        returns (uint256 dt_DepositAmount, uint256 tokenA_DepositAmount, uint256 tokenB_DepositAmount, bytes memory, bytes memory)
    {
        // Get amount deposited by the depositor (AP)
        dt_DepositAmount = marketHashToDepositorToAmountDeposited[_marketHash][_depositor];

        // Calculate amount of each constituent to bridge
        tokenA_DepositAmount = dt_DepositAmount * _amountOfTokenAPerDT;
        tokenB_DepositAmount = dt_DepositAmount * _amountOfTokenBPerDT;

        if (tokenA_DepositAmount > type(uint96).max || tokenB_DepositAmount > type(uint96).max) {
            return (0, 0, 0, _tokenA_ComposeMsg, _tokenB_ComposeMsg); // Skip if deposit amount exceeds limit
        }

        // Delete all Weiroll Wallet state and deposit amounts associated with this depositor
        _clearDepositorData(_marketHash, _depositor);

        // Update compose messages
        _tokenA_ComposeMsg = _tokenA_ComposeMsg.writeDepositor(_depositor, uint96(tokenA_DepositAmount));
        _tokenB_ComposeMsg = _tokenB_ComposeMsg.writeDepositor(_depositor, uint96(tokenB_DepositAmount));

        return (dt_DepositAmount, tokenA_DepositAmount, tokenB_DepositAmount, _tokenA_ComposeMsg, _tokenB_ComposeMsg);
    }

    /**
     * @notice Processes a Uniswap V2 LP token depositor by adjusting for bridge precision, refunding dust, and updating compose messages.
     * @dev Calculates the depositor's prorated share of the underlying tokens, adjusts amounts to match OFT bridge precision using the provided decimal
     * conversion rates,
     *      refunds any residual amounts (dust) back to the depositor, clears depositor data, and updates the compose messages.
     * @param params The parameters required for processing the LP token depositor.
     * @param _tokenA The ERC20 instance of Token A.
     * @param _tokenB The ERC20 instance of Token B.
     * @param _tokenA_ComposeMsg The compose message for Token A to be updated.
     * @param _tokenB_ComposeMsg The compose message for Token B to be updated.
     * @param totals The totals for Token A and Token B to be updated.
     */
    function _processLpTokenDepositor(
        LpTokenDepositorParams memory params,
        ERC20 _tokenA,
        ERC20 _tokenB,
        bytes memory _tokenA_ComposeMsg,
        bytes memory _tokenB_ComposeMsg,
        Totals memory totals
    )
        internal
        returns (bytes memory, bytes memory)
    {
        // Get amount deposited by the depositor (AP)
        uint256 lp_DepositAmount = marketHashToDepositorToAmountDeposited[params.marketHash][params.depositor];

        // Calculate the depositor's share of each underlying token
        uint256 tokenA_DepositAmount = (params.tokenA_TotalAmountReceivedOnBurn * lp_DepositAmount) / params.lp_TotalAmountToBridge;
        uint256 tokenB_DepositAmount = (params.tokenB_TotalAmountReceivedOnBurn * lp_DepositAmount) / params.lp_TotalAmountToBridge;

        // Adjust depositor amounts to acceptable precision and refund dust
        uint256 acceptableTokenA_DepositAmount =
            _adjustForPrecisionAndRefundDust(params.depositor, _tokenA, tokenA_DepositAmount, params.tokenA_DecimalConversionRate);
        uint256 acceptableTokenB_DepositAmount =
            _adjustForPrecisionAndRefundDust(params.depositor, _tokenB, tokenB_DepositAmount, params.tokenB_DecimalConversionRate);

        // Delete all Weiroll Wallet state and deposit amounts associated with this depositor
        _clearDepositorData(params.marketHash, params.depositor);

        // Update compose messages with acceptable amounts
        _tokenA_ComposeMsg = _tokenA_ComposeMsg.writeDepositor(params.depositor, uint96(acceptableTokenA_DepositAmount));
        _tokenB_ComposeMsg = _tokenB_ComposeMsg.writeDepositor(params.depositor, uint96(acceptableTokenB_DepositAmount));

        // Update totals
        totals.tokenA += acceptableTokenA_DepositAmount;
        totals.tokenB += acceptableTokenB_DepositAmount;

        return (_tokenA_ComposeMsg, _tokenB_ComposeMsg);
    }

    /**
     * @notice Adjusts the amount to match OFT bridge precision and refunds any dust to the depositor.
     * @dev Calculates the acceptable amount based on the provided decimal conversion rate and refunds any residual amount (dust) to the depositor.
     * @param _depositor The address of the depositor to refund dust to.
     * @param _token The ERC20 token instance.
     * @param _amountLD The original amount in local decimals.
     * @param _decimalConversionRate The decimal conversion rate (10 ** (_localDecimals - _sharedDecimals)).
     * @return acceptableAmountLD The amount adjusted to acceptable precision for bridging.
     */
    function _adjustForPrecisionAndRefundDust(
        address _depositor,
        ERC20 _token,
        uint256 _amountLD,
        uint256 _decimalConversionRate
    )
        internal
        returns (uint256 acceptableAmountLD)
    {
        acceptableAmountLD = (_amountLD / _decimalConversionRate) * _decimalConversionRate;
        uint256 dustAmount = _amountLD - acceptableAmountLD;

        // Refund any dust to the depositor
        if (dustAmount > 0) {
            _token.safeTransfer(_depositor, dustAmount);
        }

        return acceptableAmountLD;
    }

    /**
     * @notice Bridges LayerZero V2 OFT tokens.
     * @param _token The token to bridge.
     * @param _feesAlreadyPaid The amount of fees already paid in this transaction prior to this bridge.
     * @param _sendParam The send parameter passed to the quoteSend and send OFT functions.
     * @return messageReceipt The messaging receipt from the bridge operation.
     */
    function _bridgeTokens(ERC20 _token, uint256 _feesAlreadyPaid, SendParam memory _sendParam) internal returns (MessagingReceipt memory messageReceipt) {
        // The amount of the token to bridge in local decimals
        uint256 amountToBridge = _sendParam.amountLD;

        // Get the lzV2OFT for the market's input token
        IOFT lzV2OFT = tokenToLzV2OFT[_token];

        // Get fee quote for bridging
        MessagingFee memory messagingFee = lzV2OFT.quoteSend(_sendParam, false);
        require(msg.value - _feesAlreadyPaid >= messagingFee.nativeFee, InsufficientValueForBridgeFee());

        OFTReceipt memory bridgeReceipt;
        if (lzV2OFT.token() == address(0)) {
            // If OFT expects native token, unwrap the native asset tokens to bridge
            WRAPPED_NATIVE_ASSET_TOKEN.withdraw(amountToBridge);

            // Execute the bridge transaction by sending native assets to bridge + bridging fee
            (messageReceipt, bridgeReceipt) = lzV2OFT.send{ value: messagingFee.nativeFee + amountToBridge }(_sendParam, messagingFee, address(this));
        } else {
            // Approve the lzV2OFT to bridge tokens
            _token.safeApprove(address(lzV2OFT), amountToBridge);

            // Execute the bridge transaction
            (messageReceipt, bridgeReceipt) = lzV2OFT.send{ value: messagingFee.nativeFee }(_sendParam, messagingFee, address(this));
        }

        // Ensure that all deposits were bridged
        require(bridgeReceipt.amountReceivedLD == amountToBridge, FailedToBridgeAllDeposits());
    }

    /**
     * @notice Deletes all Weiroll Wallet state and deposit amounts associated with this depositor for the specified market.
     * @param _marketHash The market hash to clear the depositor data for.
     * @param _depositor The depositor to clear the depositor data for.
     */
    function _clearDepositorData(bytes32 _marketHash, address _depositor) internal {
        // Mark all currently deposited Weiroll Wallets from this depositor as bridged
        address[] storage depositorWeirollWallets = marketHashToDepositorToWeirollWallets[_marketHash][_depositor];
        for (uint256 i = 0; i < depositorWeirollWallets.length; ++i) {
            // Set the amount deposited by the Weiroll Wallet to zero
            delete depositorToWeirollWalletToAmount[_depositor][depositorWeirollWallets[i]];
        }
        // Set length of currently deposited wallets list to zero
        delete marketHashToDepositorToWeirollWallets[_marketHash][_depositor];
        // Set the total deposit amount from this depositor (AP) to zero
        delete marketHashToDepositorToAmountDeposited[_marketHash][_depositor];
    }

    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return The converted bytes32 value.
     */
    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /*//////////////////////////////////////////////////////////////
                            Administrative Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the LayerZero endpoint ID for the destination chain.
     * @param _dstChainLzEid LayerZero endpoint ID for the destination chain.
     */
    function setDestinationChainEid(uint32 _dstChainLzEid) external onlyOwner {
        dstChainLzEid = _dstChainLzEid;
    }

    /**
     * @notice Sets the LayerZero Omnichain App instance for a given token.
     * @param _token Token to set the LayerZero Omnichain App for.
     * @param _lzV2OFT LayerZero OFT to use to bridge the specified token.
     */
    function setLzV2OFTForToken(ERC20 _token, IOFT _lzV2OFT) external onlyOwner {
        // Get the underlying token for this OFT
        address underlyingToken = _lzV2OFT.token();
        // Check that the underlying token is the specified token or the chain's native asset
        require(underlyingToken == address(_token) || underlyingToken == address(0), InvalidLzV2OFTForToken());
        tokenToLzV2OFT[_token] = _lzV2OFT;
    }

    /**
     * @notice Sets the DepositExecutor address.
     * @param _depositExecutor Address of the new DepositExecutor on the destination chain.
     */
    function setDepositExecutor(address _depositExecutor) external onlyOwner {
        depositExecutor = _depositExecutor;
    }

    /**
     * @notice Sets the multisig address for a market.
     * @param _marketHash The market hash to set the multisig for.
     * @param _multisig The address of the multisig contract between the market's IP and the destination chain.
     */
    function setMulitsig(bytes32 _marketHash, address _multisig) external onlyOwner {
        marketHashToMultisig[_marketHash] = _multisig;
    }

    /**
     * @notice Sets the green light status for a market.
     * @param _marketHash The market hash to set the green light for.
     * @param _greenLightStatus Boolean indicating if funds are ready to bridge.
     */
    function setGreenLight(bytes32 _marketHash, bool _greenLightStatus) external onlyMultisig(_marketHash) {
        marketHashToGreenLight[_marketHash] = _greenLightStatus;
    }

    /**
     * @notice Let the DepositLocker receive native assets directly.
     * @dev Primarily used for receiving native assets after unwrapping the native asset token.
     */
    receive() external payable { }
}
