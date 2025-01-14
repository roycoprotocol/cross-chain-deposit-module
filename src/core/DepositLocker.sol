// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import { RecipeMarketHubBase, ERC20, SafeTransferLib } from "../../lib/royco/src/RecipeMarketHub.sol";
import { WeirollWallet } from "../../lib/royco/src/WeirollWallet.sol";
import { IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt } from "../interfaces/IOFT.sol";
import { IWETH } from "../interfaces/IWETH.sol";
import { OptionsBuilder } from "../libraries/OptionsBuilder.sol";
import { CCDMPayloadLib } from "../libraries/CCDMPayloadLib.sol";
import { CCDMFeeLib } from "../libraries/CCDMFeeLib.sol";
import { IUniswapV2Router01 } from "../../lib/v2-periphery/contracts/interfaces/IUniswapV2Router01.sol";
import { IUniswapV2Pair } from "../../lib/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import { MerkleTree } from "../../lib/openzeppelin-contracts/contracts/utils/structs/MerkleTree.sol";

/// @title DepositLocker
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A singleton contract for managing deposits for the destination chain on the source chain.
/// @notice Facilitates deposits, withdrawals, and bridging deposits for all deposit markets.
contract DepositLocker is Ownable2Step, ReentrancyGuardTransient {
    using CCDMPayloadLib for bytes;
    using OptionsBuilder for bytes;
    using SafeTransferLib for ERC20;
    using MerkleTree for MerkleTree.Bytes32PushTree;

    /*//////////////////////////////////////////////////////////////
                                Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice The depth of the Merkle Tree dictating the number of individual deposits it can hold.
    /// @dev A depth of 23 can hold 2^23 = 8,388,608 deposits.
    uint8 public constant MERKLE_TREE_DEPTH = 23;

    /// @notice The value used for a null leaf in the Merkle Tree.
    bytes32 public constant NULL_LEAF = bytes32(0);

    /// @notice The limit for how many depositors can be bridged in a single transaction
    uint256 public constant MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE = 300;

    /// @notice The duration of time that depositors have after the market's green light is given to rage quit before they can be bridged.
    uint256 public constant RAGE_QUIT_PERIOD_DURATION = 0 hours;

    /// @notice The code hash of the Uniswap V2 Pair contract.
    bytes32 internal constant UNISWAP_V2_PAIR_CODE_HASH = 0x5b83bdbcc56b2e630f2807bbadd2b0c21619108066b92a58de081261089e9ce5;

    /// @notice The number of tokens bridged for a single token CCDM bridge transaction
    uint8 internal constant NUM_TOKENS_BRIDGED_FOR_SINGLE_TOKEN_BRIDGE = 1;

    /// @notice The number of tokens bridged for an LP token CCDM bridge transaction
    uint8 internal constant NUM_TOKENS_BRIDGED_FOR_LP_TOKEN_BRIDGE = 2;

    /*//////////////////////////////////////////////////////////////
                                Structures
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct to hold total amounts for Token A and Token B.
    struct TotalAmountsToBridge {
        uint256 token0_TotalAmountToBridge;
        uint256 token1_TotalAmountToBridge;
    }

    /// @notice Struct to hold parameters for bridging LP tokens.
    struct LpBridgeParams {
        bytes32 marketHash;
        ERC20 token0;
        ERC20 token1;
        TotalAmountsToBridge totals;
        bytes token0_ComposeMsg;
        bytes token1_ComposeMsg;
        address[] depositorsBridged;
    }

    /// @notice Struct to hold parameters for processing LP token depositors.
    struct LpTokenDepositorParams {
        uint256 numDepositorsIncluded;
        address depositor;
        uint256 lpToken_DepositAmount;
        uint256 lp_TotalAmountToBridge;
        uint256 token0_TotalAmountReceivedOnBurn;
        uint256 token1_TotalAmountReceivedOnBurn;
        uint256 token0_DecimalConversionRate;
        uint256 token1_DecimalConversionRate;
    }

    /// @notice Struct to hold the info about merklized deposits for a specific market.
    struct MerkleDepositsInfo {
        MerkleTree.Bytes32PushTree merkleTree; // Merkle tree storing each deposit as a leaf.
        bytes32 merkleRoot; // Merkle root of the merkle tree representing deposits for this market.
        uint256 totalAmountDeposited; // Total amount deposited by depositors for this market.
        // The CCDM nonce of the latest merkle bridge transaction for this market. Used to handle merkle withdrawals.
        uint256 latestCcdmNonce;
        // Each Weiroll Wallet's deposit amount since the last merkle bridge for this market.
        // Signifies the amount the Weiroll Wallet has deposited into the current merkle tree when indexed with latestCcdmNonce.
        mapping(uint256 => mapping(address => uint256)) latestCcdmNonceToWeirollWalletToDepositAmount;
    }

    /// @notice Struct to hold the info about a depositor.
    struct IndividualDepositorInfo {
        uint256 totalAmountDeposited; // Total amount deposited by this depositor for this market.
        uint256 latestCcdmNonce; // Most recent CCDM nonce of the bridge txn that this depositor was included in for this market.
    }

    /// @notice Struct to hold the info about a Weiroll Wallet.
    struct WeirollWalletDepositInfo {
        uint256 amountDeposited; // The amount deposited by this specific Weiroll Wallet.
        uint256 ccdmNonceOnDeposit; // The global CCDM nonce when this Weiroll Wallet deposited into the Deposit Locker.
    }

    /*//////////////////////////////////////////////////////////////
                            State Variables
    //////////////////////////////////////////////////////////////*/

    /// @notice The RecipeMarketHub keeping track of all Royco markets and offers.
    RecipeMarketHubBase public immutable RECIPE_MARKET_HUB;

    /// @notice The wrapped native asset token on the source chain.
    IWETH public immutable WRAPPED_NATIVE_ASSET_TOKEN;

    /// @notice The Uniswap V2 router on the source chain.
    IUniswapV2Router01 public immutable UNISWAP_V2_ROUTER;

    /// @notice The hash of the Weiroll Wallet code
    bytes32 public immutable WEIROLL_WALLET_PROXY_CODE_HASH;

    /// @notice The party that green lights bridging on a per market basis
    address public greenLighter;

    /// @notice The LayerZero endpoint ID for the destination chain.
    uint32 public dstChainLzEid;

    /// @notice The address of the DepositExecutor on the destination chain.
    address public depositExecutor;

    /// @notice Mapping of an ERC20 token to its corresponding LayerZero OFT.
    /// @dev NOTE: Must implement the IOFT interface.
    mapping(ERC20 => IOFT) public tokenToLzV2OFT;

    /// @notice Mapping from market hash to the time the green light will turn on for bridging.
    mapping(bytes32 => uint256) public marketHashToBridgingAllowedTimestamp;

    /// @notice Mapping from market hash to the owner of the corresponding deposit campaign.
    mapping(bytes32 => address) public marketHashToCampaignOwner;

    /// @notice Mapping from market hash to the MerkleDepositsInfo struct.
    mapping(bytes32 => MerkleDepositsInfo) public marketHashToMerkleDepositsInfo;

    /// @notice Mapping from market hash to depositor's address to the IndividualDepositorInfo struct.
    mapping(bytes32 => mapping(address => IndividualDepositorInfo)) public marketHashToDepositorToIndividualDepositorInfo;

    /// @notice Mapping from depositor's address to Weiroll Wallet to the WeirollWalletDepositInfo struct.
    mapping(address => mapping(address => WeirollWalletDepositInfo)) public depositorToWeirollWalletToWeirollWalletDepositInfo;

    /// @notice Mapping from market hash to if deposits and bridges for a market are halted. Withdrawals are still enabled.
    /// @dev NOTE: Halting a market's deposits and bridges cannot be undone. This ensures that funds will stay on source.
    mapping(bytes32 => bool) public marketHashToHalted;

    /// @notice Used to keep track of CCDM bridge transactions.
    /// @notice A CCDM bridge transaction that results in multiple OFTs being bridged (LP bridge) will have the same nonce.
    uint256 public ccdmNonce;

    /// @notice Used to make each merkle deposit leaf is unique.
    /// @notice This allows for the depositor to withdraw correctly in the event that they make multiple deposits in the same merkle tree.
    uint256 public merkleDepositNonce;

    /*//////////////////////////////////////////////////////////////
                            Events and Errors
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a merkle deposit is made for a given market.
     * @param ccdmNonce The CCDM Nonce indicating the next bridge nonce.
     * @param marketHash The unique hash identifier of the market where the deposit occurred.
     * @param depositor The address of the user who made the deposit.
     * @param amountDeposited The amount of funds that were deposited by the user.
     * @param merkleDepositNonce Unique identifier for this merkle deposit - used to make sure that each merkle depositor's leaf is unique.
     * @param leafIndex The index in the Merkle tree where the new deposit leaf was added.
     * @param leafIndex The index in the Merkle tree where the new deposit leaf was added.
     * @param updatedMerkleRoot The new Merkle root after the deposit leaf was inserted.
     */
    event MerkleDepositMade(
        uint256 indexed ccdmNonce,
        bytes32 indexed marketHash,
        address indexed depositor,
        uint256 amountDeposited,
        uint256 merkleDepositNonce,
        bytes32 leaf,
        uint256 leafIndex,
        bytes32 updatedMerkleRoot
    );

    /**
     * @notice Emitted when a user withdraws funds from a market.
     * @param marketHash The unique hash identifier of the market from which the withdrawal was made.
     * @param depositor The address of the user who invoked the withdrawal.
     * @param amountWithdrawn The amount of funds that were withdrawn by the user.
     */
    event MerkleWithdrawalMade(bytes32 indexed marketHash, address indexed depositor, uint256 amountWithdrawn);

    /**
     * @notice Emitted when a user deposits funds into a market.
     * @param marketHash The unique hash identifier of the market where the deposit occurred.
     * @param depositor The address of the user who made the deposit.
     * @param amountDeposited The amount of funds that were deposited by the user.
     */
    event IndividualDepositMade(bytes32 indexed marketHash, address indexed depositor, uint256 amountDeposited);

    /**
     * @notice Emitted when a user withdraws funds from a market.
     * @param marketHash The unique hash identifier of the market from which the withdrawal was made.
     * @param depositor The address of the user who invoked the withdrawal.
     * @param amountWithdrawn The amount of funds that were withdrawn by the user.
     */
    event IndividualWithdrawalMade(bytes32 indexed marketHash, address indexed depositor, uint256 amountWithdrawn);

    /**
     * @notice Emitted when single tokens are merkle bridged to the destination chain.
     * @param marketHash The unique hash identifier of the market related to the bridged tokens.
     * @param ccdmNonce The CCDM Nonce for this bridge.
     * @param merkleRoot The merkle root bridged to the destination.
     * @param lz_guid The LayerZero unique identifier associated with the bridging transaction.
     * @param lz_nonce The LayerZero nonce value for the bridging message.
     * @param totalAmountBridged The total amount of tokens that were bridged to the destination chain.
     */
    event SingleTokensMerkleBridgedToDestination(
        bytes32 indexed marketHash, uint256 indexed ccdmNonce, bytes32 merkleRoot, bytes32 lz_guid, uint64 lz_nonce, uint256 totalAmountBridged
    );

    /**
     * @notice Emitted when single tokens are bridged to the destination chain.
     * @param marketHash The unique hash identifier of the market related to the bridged tokens.
     * @param ccdmNonce The CCDM Nonce for this bridge.
     * @param depositorsBridged All the depositors bridged in this CCDM bridge transaction.
     * @param lz_guid The LayerZero unique identifier associated with the bridging transaction.
     * @param lz_nonce The LayerZero nonce value for the bridging message.
     * @param totalAmountBridged The total amount of tokens that were bridged to the destination chain.
     */
    event SingleTokensBridgedToDestination(
        bytes32 indexed marketHash, uint256 indexed ccdmNonce, address[] depositorsBridged, bytes32 lz_guid, uint64 lz_nonce, uint256 totalAmountBridged
    );

    /**
     * @notice Emitted when UNI V2 LP tokens are merkle bridged to the destination chain.
     * @param marketHash The unique hash identifier of the market associated with the LP tokens.
     * @param ccdmNonce The CCDM Nonce for this bridge.
     * @param merkleRoot The merkle root bridged to the destination.
     * @param lz_token0_guid The LayerZero unique identifier for the bridging of token0.
     * @param lz_token0_nonce The LayerZero nonce value for the bridging of token0.
     * @param token0 The address of the first token in the liquidity pair.
     * @param lz_token0_AmountBridged The amount of token0 that was bridged to the destination chain.
     * @param lz_token1_guid The LayerZero unique identifier for the bridging of token1.
     * @param lz_token1_nonce The LayerZero nonce value for the bridging of token1.
     * @param token1 The address of the second token in the liquidity pair.
     * @param lz_token1_AmountBridged The amount of token1 that was bridged to the destination chain.
     */
    event LpTokensMerkleBridgedToDestination(
        bytes32 indexed marketHash,
        uint256 indexed ccdmNonce,
        bytes32 merkleRoot,
        bytes32 lz_token0_guid,
        uint64 lz_token0_nonce,
        ERC20 token0,
        uint256 lz_token0_AmountBridged,
        bytes32 lz_token1_guid,
        uint64 lz_token1_nonce,
        ERC20 token1,
        uint256 lz_token1_AmountBridged
    );

    /**
     * @notice Emitted when UNI V2 LP tokens are bridged to the destination chain.
     * @param marketHash The unique hash identifier of the market associated with the LP tokens.
     * @param ccdmNonce The CCDM Nonce for this bridge.
     * @param depositorsBridged All the depositors bridged in this CCDM bridge transaction.
     * @param lz_token0_guid The LayerZero unique identifier for the bridging of token0.
     * @param lz_token0_nonce The LayerZero nonce value for the bridging of token0.
     * @param token0 The address of the first token in the liquidity pair.
     * @param lz_token0_AmountBridged The amount of token0 that was bridged to the destination chain.
     * @param lz_token1_guid The LayerZero unique identifier for the bridging of token1.
     * @param lz_token1_nonce The LayerZero nonce value for the bridging of token1.
     * @param token1 The address of the second token in the liquidity pair.
     * @param lz_token1_AmountBridged The amount of token1 that was bridged to the destination chain.
     */
    event LpTokensBridgedToDestination(
        bytes32 indexed marketHash,
        uint256 indexed ccdmNonce,
        address[] depositorsBridged,
        bytes32 lz_token0_guid,
        uint64 lz_token0_nonce,
        ERC20 token0,
        uint256 lz_token0_AmountBridged,
        bytes32 lz_token1_guid,
        uint64 lz_token1_nonce,
        ERC20 token1,
        uint256 lz_token1_AmountBridged
    );

    /**
     * @notice Emitted when the destination chain LayerZero endpoint ID is set.
     * @param dstChainLzEid The new LayerZero endpoint ID for the destination chain.
     */
    event DestinationChainLzEidSet(uint32 dstChainLzEid);

    /**
     * @notice Emitted when the Deposit Executor address is set.
     * @param depositExecutor The new address of the Deposit Executor on the destination chain.
     */
    event DepositExecutorSet(address depositExecutor);

    /**
     * @notice Emitted when the owner of the market's corresponding deposit campaign is set.
     * @param marketHash The hash of the market for which to set the deposit campaign owner for.
     * @param campaignOwner The address of the owner of the market's corresponding deposit campaign.
     */
    event CampaignOwnerSet(bytes32 indexed marketHash, address campaignOwner);

    /**
     * @notice Emitted when the LayerZero V2 OFT for a token is set.
     * @param token The address of the underlying token.
     * @param lzV2OFT The LayerZero V2 OFT contract address for the token.
     */
    event LzV2OFTForTokenSet(address indexed token, address lzV2OFT);

    /**
     * @notice Emitted when the LayerZero V2 OFT for a token is removed.
     * @param token The address of the underlying token.
     */
    event LzV2OFTForTokenRemoved(address indexed token);

    /**
     * @notice Emitted when the green lighter address is set.
     * @param greenLighter The new address of the green lighter.
     */
    event GreenLighterSet(address greenLighter);

    /**
     * @notice Emitted when deposits and bridging are eternally halted for a market. Withdrawals still are still functional.
     * @param marketHash The hash of the market for which deposits and bridging have been halted.
     */
    event MarketHalted(bytes32 marketHash);

    /**
     * @notice Emitted when the green light is turned on for a market.
     * @param marketHash The hash of the market for which the green light was turned on for.
     * @param bridgingAllowedTimestamp The timestamp when deposits will be bridgable (RAGE_QUIT_PERIOD_DURATION after the green light was turned on).
     */
    event GreenLightTurnedOn(bytes32 indexed marketHash, uint256 bridgingAllowedTimestamp);

    /**
     * @notice Emitted when the green light is turned off for a market.
     * @param marketHash The hash of the market for which the green light was turned off for.
     */
    event GreenLightTurnedOff(bytes32 indexed marketHash);

    /// @notice Error emitted when calling deposit from an address that isn't a Weiroll Wallet.
    error OnlyWeirollWallet();

    /// @notice Error emitted when trying to deposit into the locker for a Royco market that is either not created or has an undeployed input token.
    error RoycoMarketNotInitialized();

    /// @notice Error emitted when calling withdraw with nothing deposited
    error NothingToWithdraw();

    /// @notice Error emitted when trying to deposit into or bridge funds for a market that has been halted.
    error MarketIsHalted();

    /// @notice Error emitted when trying to merkle withdraw from a market that has not been halted.
    error MerkleWithdrawalsNotEnabled();

    /// @notice Error emitted when green light is not given for bridging.
    error GreenLightNotGiven();

    /// @notice Error emitted when trying to bridge during the rage quit period.
    error RageQuitPeriodInProgress();

    /// @notice Error emitted when trying to bridge funds to an uninitialized destination chain.
    error DestinationChainEidNotSet();

    /// @notice Error emitted when trying to bridge funds to an uninitialized deposit executor.
    error DepositExecutorNotSet();

    /// @notice Error emitted when the caller is not the global greenLighter.
    error OnlyGreenLighter();

    /// @notice Error emitted when the caller is not the owner of the market's corresponding deposit campaign.
    error OnlyCampaignOwner();

    /// @notice Error emitted when the deposit amount is too precise to bridge based on the shared decimals of the OFT
    error DepositAmountIsTooPrecise();

    /// @notice Error emitted when the total deposit amount for the depositor exceeds the per market limit in a single bridge.
    error TotalDepositAmountExceedsLimit();

    /// @notice Error emitted when trying to bridge LP tokens as a single token.
    error CannotBridgeLpTokens();

    /// @notice Error emitted when attempting to bridge more depositors than the bridge limit
    error DepositorsPerBridgeLimitExceeded();

    /// @notice Error emitted when attempting to bridge 0 depositors.
    error MustBridgeAtLeastOneDepositor();

    /// @notice Error emitted when insufficient msg.value is provided for the bridge fee.
    error InsufficientValueForBridgeFee();

    /// @notice Error emitted when bridging all the specified deposits fails.
    error FailedToBridgeAllDeposits();

    /// @notice Error emitted when the lengths of the source market hashes and owners array don't match in the constructor.
    error ArrayLengthMismatch();

    /// @notice Error emitted when transferring back excess msg.value fails.
    error RefundFailed();

    /*//////////////////////////////////////////////////////////////
                                Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is a Weiroll Wallet created using the clone with immutable args pattern.
    modifier onlyWeirollWallet() {
        bytes memory code = msg.sender.code;
        bytes32 codeHash;
        assembly ("memory-safe") {
            // Get code hash of the runtime bytecode without the immutable args
            codeHash := keccak256(add(code, 32), 56)
        }

        // Check that the length is valid and the codeHash matches that of a Weiroll Wallet proxy
        require(code.length == 195 && codeHash == WEIROLL_WALLET_PROXY_CODE_HASH, OnlyWeirollWallet());
        _;
    }

    /// @dev Modifier to ensure the caller is the authorized multisig for the market.
    modifier onlyGreenLighter() {
        require(msg.sender == greenLighter, OnlyGreenLighter());
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the market's corresponding deposit campaign or owner of the Deposit Locker.
    modifier onlyCampaignOwnerOrDepositLockerOwner(bytes32 _marketHash) {
        require(msg.sender == marketHashToCampaignOwner[_marketHash] || msg.sender == owner(), OnlyCampaignOwner());
        _;
    }

    /// @dev Modifier to check if the bridge is ready to be invoked.
    modifier readyToBridge(bytes32 _marketHash) {
        // Basic checks for bridge readiness
        require(msg.sender == marketHashToCampaignOwner[_marketHash], OnlyCampaignOwner());
        require(!marketHashToHalted[_marketHash], MarketIsHalted());
        require(dstChainLzEid != 0, DestinationChainEidNotSet());
        require(depositExecutor != address(0), DepositExecutorNotSet());
        // Green light related bridge checks
        uint256 bridgingAllowedTimestamp = marketHashToBridgingAllowedTimestamp[_marketHash];
        require(bridgingAllowedTimestamp != 0, GreenLightNotGiven());
        require(block.timestamp >= bridgingAllowedTimestamp, RageQuitPeriodInProgress());
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
     * @param _greenLighter The address of the global green lighter responsible for marking deposits as bridgable.
     * @param _recipeMarketHub The address of the recipe market hub used to create markets on the source chain.
     * @param _uniswap_v2_router The address of the Uniswap V2 router on the source chain.
     * @param _lzV2OFTs The LayerZero V2 OFT instances for each acceptable deposit token on the source chain.
     */
    constructor(
        address _owner,
        uint32 _dstChainLzEid,
        address _depositExecutor,
        address _greenLighter,
        RecipeMarketHubBase _recipeMarketHub,
        IUniswapV2Router01 _uniswap_v2_router,
        IOFT[] memory _lzV2OFTs
    )
        Ownable(_owner)
    {
        // Initialize the contract state
        RECIPE_MARKET_HUB = _recipeMarketHub;
        WRAPPED_NATIVE_ASSET_TOKEN = IWETH(_uniswap_v2_router.WETH());
        UNISWAP_V2_ROUTER = _uniswap_v2_router;
        WEIROLL_WALLET_PROXY_CODE_HASH = keccak256(
            abi.encodePacked(
                hex"363d3d3761008b603836393d3d3d3661008b013d73", _recipeMarketHub.WEIROLL_WALLET_IMPLEMENTATION(), hex"5af43d82803e903d91603657fd5bf3"
            )
        );
        ccdmNonce = 1; // The first CCDM bridge transaction will have a nonce of 1

        for (uint256 i = 0; i < _lzV2OFTs.length; ++i) {
            _setLzV2OFTForToken(_lzV2OFTs[i]);
        }

        greenLighter = _greenLighter;
        emit GreenLighterSet(_greenLighter);

        dstChainLzEid = _dstChainLzEid;
        emit DestinationChainLzEidSet(_dstChainLzEid);

        depositExecutor = _depositExecutor;
        emit DepositExecutorSet(_depositExecutor);
    }

    /*//////////////////////////////////////////////////////////////
                            External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits a depositor into the Deposit Locker as a merklized deposit for this Weiroll Wallet.
     * @dev Each merklized deposit made needs to be withdrawn individually on the destination.
     * @dev Called by the deposit script of the depositor's Weiroll Wallet.
     * @dev Requires an approval of the deposit amount for the market's input token.
     */
    function merkleDeposit() external nonReentrant onlyWeirollWallet {
        // Get Weiroll Wallet's market hash, depositor/owner/AP, and amount deposited
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        bytes32 targetMarketHash = wallet.marketHash();
        address depositor = wallet.owner();
        uint256 amountDeposited = wallet.amount();

        // Check that the target market isn't halted
        require(!marketHashToHalted[targetMarketHash], MarketIsHalted());

        // Get the token to deposit for this market
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);

        // Check to avoid frontrunning deposits before a market has been created or the market's input token is deployed
        require(address(marketInputToken).code.length != 0, RoycoMarketNotInitialized());

        if (!_isUniV2Pair(address(marketInputToken))) {
            // Check that the deposit amount is less or equally as precise as specified by the shared decimals of the OFT for SINGLE_TOKEN markets
            bool depositAmountHasValidPrecision =
                amountDeposited % (10 ** (marketInputToken.decimals() - tokenToLzV2OFT[marketInputToken].sharedDecimals())) == 0;
            require(depositAmountHasValidPrecision, DepositAmountIsTooPrecise());
        }

        // Transfer the deposit amount from the Weiroll Wallet to the Deposit Locker
        marketInputToken.safeTransferFrom(msg.sender, address(this), amountDeposited);

        // Get the merkleDepositsInfo struct for the intended market
        MerkleDepositsInfo storage merkleDepositsInfo = marketHashToMerkleDepositsInfo[targetMarketHash];
        if (merkleDepositsInfo.merkleTree.depth() == 0) {
            // If the tree is uninitialized, initialize it with the depth
            merkleDepositsInfo.merkleTree.setup(MERKLE_TREE_DEPTH, NULL_LEAF);
        }
        // Generate the deposit leaf
        bytes32 depositLeaf = keccak256(abi.encodePacked(merkleDepositNonce, depositor, amountDeposited));
        // Add the deposit leaf to the Merkle Tree
        (uint256 leafIndex, bytes32 updatedMerkleRoot) = merkleDepositsInfo.merkleTree.push(depositLeaf);
        // Update the merkle root and the total amount deposited into the merkle tree
        merkleDepositsInfo.merkleRoot = updatedMerkleRoot;
        merkleDepositsInfo.totalAmountDeposited += amountDeposited;
        // Update the amount this Weiroll Wallet has deposited into the currently stored merkle tree.
        merkleDepositsInfo.latestCcdmNonceToWeirollWalletToDepositAmount[merkleDepositsInfo.latestCcdmNonce][msg.sender] = amountDeposited;

        // Emit merkle deposit event
        emit MerkleDepositMade(ccdmNonce, targetMarketHash, depositor, amountDeposited, merkleDepositNonce++, depositLeaf, leafIndex, updatedMerkleRoot);
    }

    /**
     * @notice Directly withdraws the amount deposited into the Deposit Locker from an individual depositor's Weiroll Wallet to the depositor/AP.
     * @dev NOTE: Market MUST be halted for this function to be called.
     * @dev Called by the withdraw script of the depositor's Weiroll Wallet.
     */
    function merkleWithdrawal() external nonReentrant {
        // Get Weiroll Wallet's market hash and depositor/owner/AP
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        bytes32 targetMarketHash = wallet.marketHash();
        address depositor = wallet.owner();

        // Check that the target market is halted, indicating that merkle withdrawals are enabled
        require(marketHashToHalted[targetMarketHash], MerkleWithdrawalsNotEnabled());

        // Get the merkleDepositsInfo struct for the intended market
        MerkleDepositsInfo storage merkleDepositsInfo = marketHashToMerkleDepositsInfo[targetMarketHash];
        uint256 latestCcdmNonce = merkleDepositsInfo.latestCcdmNonce;
        // Get the withdrawable amount from the current merkle tree for this Weiroll Wallet
        uint256 amountToWithdraw = merkleDepositsInfo.latestCcdmNonceToWeirollWalletToDepositAmount[latestCcdmNonce][msg.sender];

        // Ensure that this Weiroll Wallet's deposit hasn't been bridged and this Weiroll Wallet hasn't withdrawn.
        require(amountToWithdraw > 0, NothingToWithdraw());

        // Account for the withdrawal
        delete merkleDepositsInfo.latestCcdmNonceToWeirollWalletToDepositAmount[latestCcdmNonce][msg.sender];

        // Transfer back the amount deposited directly to the AP
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);
        marketInputToken.safeTransfer(depositor, amountToWithdraw);

        // Emit withdrawal event
        emit MerkleWithdrawalMade(targetMarketHash, depositor, amountToWithdraw);
    }

    /**
     * @notice Directly deposits a depositor as an individual depositor into the Deposit Locker.
     * @dev Called by the deposit script of the depositor's Weiroll Wallet.
     * @dev Requires an approval of the deposit amount for the market's input token.
     */
    function deposit() external nonReentrant onlyWeirollWallet {
        // Get Weiroll Wallet's market hash, depositor/owner/AP, and amount deposited
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        bytes32 targetMarketHash = wallet.marketHash();
        address depositor = wallet.owner();
        uint256 amountDeposited = wallet.amount();

        require(!marketHashToHalted[targetMarketHash], MarketIsHalted());

        // Get the token to deposit for this market
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);

        // Check to avoid frontrunning deposits before a market has been created or the market's input token is deployed
        require(address(marketInputToken).code.length != 0, RoycoMarketNotInitialized());

        // Get the individual depositor info
        IndividualDepositorInfo storage depositorInfo = marketHashToDepositorToIndividualDepositorInfo[targetMarketHash][depositor];
        uint256 totalDepositAmountPostDeposit = depositorInfo.totalAmountDeposited + amountDeposited;

        if (!_isUniV2Pair(address(marketInputToken))) {
            // Check that the deposit amount is less or equally as precise as specified by the shared decimals of the OFT for single token markets
            bool depositAmountHasValidPrecision =
                amountDeposited % (10 ** (marketInputToken.decimals() - tokenToLzV2OFT[marketInputToken].sharedDecimals())) == 0;
            require(depositAmountHasValidPrecision, DepositAmountIsTooPrecise());
            // Check that the deposit amount isn't exceeding the max amount that can be individually bridged in a single bridge
            require(totalDepositAmountPostDeposit <= type(uint96).max, TotalDepositAmountExceedsLimit());
        }

        // Transfer the deposit amount from the Weiroll Wallet to the Deposit Locker
        marketInputToken.safeTransferFrom(msg.sender, address(this), amountDeposited);

        // Account for deposit
        depositorInfo.totalAmountDeposited = totalDepositAmountPostDeposit;
        WeirollWalletDepositInfo storage walletInfo = depositorToWeirollWalletToWeirollWalletDepositInfo[depositor][msg.sender];
        walletInfo.ccdmNonceOnDeposit = ccdmNonce;
        walletInfo.amountDeposited = amountDeposited;

        // Emit deposit event
        emit IndividualDepositMade(targetMarketHash, depositor, amountDeposited);
    }

    /**
     * @notice Directly withdraws the amount deposited into the Deposit Locker from an individual depositor's Weiroll Wallet to the depositor/AP.
     * @dev Called by the withdraw script of the depositor's Weiroll Wallet.
     */
    function withdraw() external nonReentrant {
        // Get Weiroll Wallet's market hash and depositor/owner/AP
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        bytes32 targetMarketHash = wallet.marketHash();
        address depositor = wallet.owner();

        // Get the necessary depositor and Weiroll Wallet info to process the withdrawal
        IndividualDepositorInfo storage depositorInfo = marketHashToDepositorToIndividualDepositorInfo[targetMarketHash][depositor];
        WeirollWalletDepositInfo storage walletInfo = depositorToWeirollWalletToWeirollWalletDepositInfo[depositor][msg.sender];

        // Get amount to withdraw for this Weiroll Wallet
        uint256 amountToWithdraw = walletInfo.amountDeposited;
        // Ensure that this Weiroll Wallet's deposit hasn't been bridged and this Weiroll Wallet hasn't withdrawn.
        require(walletInfo.ccdmNonceOnDeposit > depositorInfo.latestCcdmNonce && amountToWithdraw > 0, NothingToWithdraw());

        // Account for the withdrawal
        depositorInfo.totalAmountDeposited -= amountToWithdraw;
        delete walletInfo.amountDeposited;

        // Transfer back the amount deposited directly to the AP
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);
        marketInputToken.safeTransfer(depositor, amountToWithdraw);

        // Emit withdrawal event
        emit IndividualWithdrawalMade(targetMarketHash, depositor, amountToWithdraw);
    }

    /**
     * @notice Merkle bridges depositors in single token markets from the source chain to the destination chain.
     * @dev NOTE: Be generous with the msg.value to pay for bridging fees, as you will be refunded the excess.
     * @dev Green light must be given before calling.
     * @param _marketHash The hash of the market to merkle bridge tokens for.
     */
    function merkleBridgeSingleTokens(bytes32 _marketHash) external payable readyToBridge(_marketHash) nonReentrant {
        // The CCDM nonce for this CCDM bridge transaction
        uint256 nonce = ccdmNonce;
        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        require(!_isUniV2Pair(address(marketInputToken)), CannotBridgeLpTokens());

        // Get merkleDepositsInfo for the specified market
        MerkleDepositsInfo storage merkleDepositsInfo = marketHashToMerkleDepositsInfo[_marketHash];
        bytes32 merkleRoot = merkleDepositsInfo.merkleRoot;
        uint256 totalAmountDeposited = merkleDepositsInfo.totalAmountDeposited;

        // Ensure that at least one depositor was included in the bridge payload
        require(totalAmountDeposited > 0, MustBridgeAtLeastOneDepositor());

        // Initialize compose message
        bytes memory composeMsg = CCDMPayloadLib.initComposeMsg(
            0, _marketHash, nonce, NUM_TOKENS_BRIDGED_FOR_SINGLE_TOKEN_BRIDGE, marketInputToken.decimals(), CCDMPayloadLib.BridgeType.MERKLE_DEPOSITORS
        );
        // Write the merkle root and the deposits it holds to the compose message
        composeMsg.writeMerkleBridgeData(merkleRoot, totalAmountDeposited);

        // Estimate gas used by the lzCompose call for this bridge transaction
        uint128 destinationGasLimit = CCDMFeeLib.GAS_FOR_MERKLE_BRIDGE;

        // Execute the bridge
        MessagingReceipt memory messageReceipt = _executeBridge(marketInputToken, totalAmountDeposited, composeMsg, 0, destinationGasLimit);
        uint256 bridgingFee = messageReceipt.fee.nativeFee;

        // Refund any excess value sent with the transaction
        if (msg.value > bridgingFee) {
            (bool success,) = payable(msg.sender).call{ value: msg.value - bridgingFee }("");
            require(success, RefundFailed());
        }

        // Reset the merkle tree and its accounting infor for this market
        merkleDepositsInfo.merkleTree.setup(MERKLE_TREE_DEPTH, NULL_LEAF);
        merkleDepositsInfo.latestCcdmNonce = nonce;
        delete merkleDepositsInfo.merkleRoot;
        delete merkleDepositsInfo.totalAmountDeposited;

        // Emit event to keep track of bridged deposits
        emit SingleTokensMerkleBridgedToDestination(_marketHash, ccdmNonce++, merkleRoot, messageReceipt.guid, messageReceipt.nonce, totalAmountDeposited);
    }

    /**
     * @notice Merkle bridges depositors in Uniswap V2 LP token markets from the source chain to the destination chain.
     * @dev NOTE: Be generous with the msg.value to pay for bridging fees, as you will be refunded the excess.
     * @dev NOTE: Dust amount after redeeming LP tokens and normalizing between the OFT's LD and SD is locked in the locker forever.
     * @dev NOTE: Dust does not scale with the number of deposits being merkle bridged.
     * @dev Green light must be given before calling.
     * @param _marketHash The hash of the market to bridge tokens for.
     * @param _minAmountOfToken0ToBridge The minimum amount of Token A to receive from removing liquidity.
     * @param _minAmountOfToken1ToBridge The minimum amount of Token B to receive from removing liquidity.
     */
    function merkleBridgeLpTokens(
        bytes32 _marketHash,
        uint96 _minAmountOfToken0ToBridge,
        uint96 _minAmountOfToken1ToBridge
    )
        external
        payable
        readyToBridge(_marketHash)
        nonReentrant
    {
        // Get merkleDepositsInfo for the specified market
        MerkleDepositsInfo storage merkleDepositsInfo = marketHashToMerkleDepositsInfo[_marketHash];
        bytes32 merkleRoot = merkleDepositsInfo.merkleRoot;
        uint256 totalAmountDeposited = merkleDepositsInfo.totalAmountDeposited;

        // The CCDM nonce for this CCDM bridge transaction
        uint256 nonce = ccdmNonce;
        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        // Initialize the Uniswap V2 pair from the market's input token
        IUniswapV2Pair uniV2Pair = IUniswapV2Pair(address(marketInputToken));
        // Approve the LP tokens to be spent by the Uniswap V2 Router
        marketInputToken.safeApprove(address(UNISWAP_V2_ROUTER), totalAmountDeposited);

        // Get the constituent tokens in the Uniswap V2 Pair
        ERC20 token0 = ERC20(uniV2Pair.token0());
        ERC20 token1 = ERC20(uniV2Pair.token1());

        // Burn the LP tokens and retrieve the pair's underlying tokens
        (uint256 token0_TotalAmountToBridge, uint256 token1_TotalAmountToBridge) = UNISWAP_V2_ROUTER.removeLiquidity(
            address(token0), address(token1), totalAmountDeposited, _minAmountOfToken0ToBridge, _minAmountOfToken1ToBridge, address(this), block.timestamp
        );

        // Normalize deposit amounts to the OFT's SD
        // IMPORTANT: Dust amount is locked in the Deposit Locker forever.
        // Dust does not scale with the number of deposits bridged.
        uint256 token0_DecimalConversionRate = 10 ** (token0.decimals() - tokenToLzV2OFT[token0].sharedDecimals());
        uint256 token1_DecimalConversionRate = 10 ** (token1.decimals() - tokenToLzV2OFT[token1].sharedDecimals());
        if (token0_DecimalConversionRate != 1) {
            token0_TotalAmountToBridge = (token0_TotalAmountToBridge / token0_DecimalConversionRate) * token0_DecimalConversionRate;
        }
        if (token1_DecimalConversionRate != 1) {
            token1_TotalAmountToBridge = (token1_TotalAmountToBridge / token1_DecimalConversionRate) * token1_DecimalConversionRate;
        }

        // Ensure that at least one depositor was included in the bridge payload
        require(token0_TotalAmountToBridge > 0 && token1_TotalAmountToBridge > 0, MustBridgeAtLeastOneDepositor());

        // Initialize compose messages for both tokens
        bytes memory token0_ComposeMsg = CCDMPayloadLib.initComposeMsg(
            0, _marketHash, nonce, NUM_TOKENS_BRIDGED_FOR_LP_TOKEN_BRIDGE, token0.decimals(), CCDMPayloadLib.BridgeType.MERKLE_DEPOSITORS
        );
        bytes memory token1_ComposeMsg = CCDMPayloadLib.initComposeMsg(
            0, _marketHash, nonce, NUM_TOKENS_BRIDGED_FOR_LP_TOKEN_BRIDGE, token1.decimals(), CCDMPayloadLib.BridgeType.MERKLE_DEPOSITORS
        );

        // Write the merkle root and the deposits they hold to the compose messages
        token0_ComposeMsg.writeMerkleBridgeData(merkleRoot, totalAmountDeposited);
        token1_ComposeMsg.writeMerkleBridgeData(merkleRoot, totalAmountDeposited);

        // Bridge the two consecutive tokens
        uint256 totalBridgingFee = 0;
        uint128 destinationGasLimit = CCDMFeeLib.GAS_FOR_MERKLE_BRIDGE;

        // Bridge Token A
        MessagingReceipt memory token0_MessageReceipt =
            _executeBridge(token0, token0_TotalAmountToBridge, token0_ComposeMsg, totalBridgingFee, destinationGasLimit);
        totalBridgingFee += token0_MessageReceipt.fee.nativeFee;

        // Bridge Token B
        MessagingReceipt memory token1_MessageReceipt =
            _executeBridge(token1, token1_TotalAmountToBridge, token1_ComposeMsg, totalBridgingFee, destinationGasLimit);
        totalBridgingFee += token1_MessageReceipt.fee.nativeFee;

        // Refund excess value sent with the transaction
        if (msg.value > totalBridgingFee) {
            (bool success,) = payable(msg.sender).call{ value: msg.value - totalBridgingFee }("");
            require(success, RefundFailed());
        }

        // Reset the merkle tree and its accounting information for this market
        merkleDepositsInfo.merkleTree.setup(MERKLE_TREE_DEPTH, NULL_LEAF);
        merkleDepositsInfo.latestCcdmNonce = nonce;
        delete merkleDepositsInfo.merkleRoot;
        delete merkleDepositsInfo.totalAmountDeposited;

        // Emit event to keep track of bridged deposits
        emit LpTokensMerkleBridgedToDestination(
            _marketHash,
            ccdmNonce++,
            merkleRoot,
            token0_MessageReceipt.guid,
            token0_MessageReceipt.nonce,
            token0,
            token0_TotalAmountToBridge,
            token1_MessageReceipt.guid,
            token1_MessageReceipt.nonce,
            token1,
            token1_TotalAmountToBridge
        );
    }

    /**
     * @notice Bridges depositors in single token markets from the source chain to the destination chain.
     * @dev NOTE: Be generous with the msg.value to pay for bridging fees, as you will be refunded the excess.
     * @dev Green light must be given before calling.
     * @param _marketHash The hash of the market to bridge tokens for.
     * @param _depositors The addresses of the depositors (APs) to bridge
     */
    function bridgeSingleTokens(bytes32 _marketHash, address[] calldata _depositors) external payable readyToBridge(_marketHash) nonReentrant {
        // The CCDM nonce for this CCDM bridge transaction
        uint256 nonce = ccdmNonce;
        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        require(!_isUniV2Pair(address(marketInputToken)), CannotBridgeLpTokens());

        // Initialize compose message
        bytes memory composeMsg = CCDMPayloadLib.initComposeMsg(
            _depositors.length,
            _marketHash,
            nonce,
            NUM_TOKENS_BRIDGED_FOR_SINGLE_TOKEN_BRIDGE,
            marketInputToken.decimals(),
            CCDMPayloadLib.BridgeType.INDIVIDUAL_DEPOSITORS
        );

        // Array to store the actual depositors bridged
        address[] memory depositorsBridged = new address[](_depositors.length);

        // Keep track of total amount of deposits to bridge and depositors included in the bridge payload.
        uint256 totalAmountToBridge;
        uint256 numDepositorsIncluded;

        for (uint256 i = 0; i < _depositors.length; ++i) {
            // Process depositor and update the compose message with depositor info
            uint256 depositAmount = _processSingleTokenDepositor(_marketHash, numDepositorsIncluded, _depositors[i], nonce, composeMsg);
            if (depositAmount == 0) {
                // If this depositor was omitted, continue.
                continue;
            }
            totalAmountToBridge += depositAmount;
            depositorsBridged[numDepositorsIncluded++] = _depositors[i];
        }

        // Ensure that at least one depositor was included in the bridge payload
        require(totalAmountToBridge > 0, MustBridgeAtLeastOneDepositor());
        // Ensure that the number of depositors bridged is less than the globally defined limit
        require(numDepositorsIncluded <= MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE, DepositorsPerBridgeLimitExceeded());

        // Resize the compose message to reflect the actual number of depositors included in the payload
        composeMsg.resizeComposeMsg(numDepositorsIncluded);

        // Resize depositors bridged array to reflect the actual number of depositors bridged
        assembly ("memory-safe") {
            mstore(depositorsBridged, numDepositorsIncluded)
        }

        // Estimate gas used by the lzCompose call for this bridge transaction
        uint128 destinationGasLimit = CCDMFeeLib.estimateIndividualDepositorsBridgeGasLimit(numDepositorsIncluded);

        // Execute the bridge
        MessagingReceipt memory messageReceipt = _executeBridge(marketInputToken, totalAmountToBridge, composeMsg, 0, destinationGasLimit);
        uint256 bridgingFee = messageReceipt.fee.nativeFee;

        // Refund any excess value sent with the transaction
        if (msg.value > bridgingFee) {
            (bool success,) = payable(msg.sender).call{ value: msg.value - bridgingFee }("");
            require(success, RefundFailed());
        }

        // Emit event to keep track of bridged deposits
        emit SingleTokensBridgedToDestination(_marketHash, ccdmNonce++, depositorsBridged, messageReceipt.guid, messageReceipt.nonce, totalAmountToBridge);
    }

    /**
     * @notice Bridges depositors in Uniswap V2 LP token markets from the source chain to the destination chain.
     * @dev NOTE: Be generous with the msg.value to pay for bridging fees, as you will be refunded the excess.
     * @dev Handles bridge precision by adjusting amounts to acceptable precision and refunding any dust to depositors.
     * @dev Green light must be given before calling.
     * @param _marketHash The hash of the market to bridge tokens for.
     * @param _minAmountOfToken0ToBridge The minimum amount of Token A to receive from removing liquidity.
     * @param _minAmountOfToken1ToBridge The minimum amount of Token B to receive from removing liquidity.
     * @param _depositors The addresses of the depositors (APs) to bridge.
     */
    function bridgeLpTokens(
        bytes32 _marketHash,
        uint96 _minAmountOfToken0ToBridge,
        uint96 _minAmountOfToken1ToBridge,
        address[] calldata _depositors
    )
        external
        payable
        readyToBridge(_marketHash)
        nonReentrant
    {
        // The CCDM nonce for this CCDM bridge transaction
        uint256 nonce = ccdmNonce;

        // Get deposit amount for each depositor and total deposit amount for this batch
        uint256 lp_TotalDepositsInBatch = 0;
        uint256[] memory lp_DepositAmounts = new uint256[](_depositors.length);
        for (uint256 i = 0; i < _depositors.length; ++i) {
            IndividualDepositorInfo storage depositorInfo = marketHashToDepositorToIndividualDepositorInfo[_marketHash][_depositors[i]];
            lp_DepositAmounts[i] = depositorInfo.totalAmountDeposited;
            lp_TotalDepositsInBatch += lp_DepositAmounts[i];
            // Set the total amount deposited by this depositor (AP) for this market to zero
            delete depositorInfo.totalAmountDeposited;
            // Mark the current CCDM nonce as the latest CCDM bridge txn that this depositor was included in for this market.
            depositorInfo.latestCcdmNonce = nonce;
        }

        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        // Initialize the Uniswap V2 pair from the market's input token
        IUniswapV2Pair uniV2Pair = IUniswapV2Pair(address(marketInputToken));
        // Approve the LP tokens to be spent by the Uniswap V2 Router
        marketInputToken.safeApprove(address(UNISWAP_V2_ROUTER), lp_TotalDepositsInBatch);

        // Get the constituent tokens in the Uniswap V2 Pair
        ERC20 token0 = ERC20(uniV2Pair.token0());
        ERC20 token1 = ERC20(uniV2Pair.token1());

        // Burn the LP tokens and retrieve the pair's underlying tokens
        (uint256 token0_AmountReceivedOnBurn, uint256 token1_AmountReceivedOnBurn) = UNISWAP_V2_ROUTER.removeLiquidity(
            address(token0), address(token1), lp_TotalDepositsInBatch, _minAmountOfToken0ToBridge, _minAmountOfToken1ToBridge, address(this), block.timestamp
        );

        // Initialize compose messages for both tokens
        bytes memory token0_ComposeMsg = CCDMPayloadLib.initComposeMsg(
            _depositors.length, _marketHash, nonce, NUM_TOKENS_BRIDGED_FOR_LP_TOKEN_BRIDGE, token0.decimals(), CCDMPayloadLib.BridgeType.INDIVIDUAL_DEPOSITORS
        );
        bytes memory token1_ComposeMsg = CCDMPayloadLib.initComposeMsg(
            _depositors.length, _marketHash, nonce, NUM_TOKENS_BRIDGED_FOR_LP_TOKEN_BRIDGE, token1.decimals(), CCDMPayloadLib.BridgeType.INDIVIDUAL_DEPOSITORS
        );

        // Create params struct
        LpTokenDepositorParams memory params;
        params.lp_TotalAmountToBridge = lp_TotalDepositsInBatch;
        params.token0_TotalAmountReceivedOnBurn = token0_AmountReceivedOnBurn;
        params.token1_TotalAmountReceivedOnBurn = token1_AmountReceivedOnBurn;
        // Get conversion rate between LD and SD to calculate dust amounts to refund
        params.token0_DecimalConversionRate = 10 ** (token0.decimals() - tokenToLzV2OFT[token0].sharedDecimals());
        params.token1_DecimalConversionRate = 10 ** (token1.decimals() - tokenToLzV2OFT[token1].sharedDecimals());

        // Initialize an array to store the actual depositors bridged
        address[] memory depositorsBridged = new address[](_depositors.length);

        // Initialize totals
        TotalAmountsToBridge memory totals;

        // Marshal the bridge payload for each token's bridge
        for (uint256 i = 0; i < _depositors.length; ++i) {
            // Modify params struct for this depositor
            params.depositor = _depositors[i];
            params.lpToken_DepositAmount = lp_DepositAmounts[i];

            // Process the depositor and update the compose messages and totals
            _processLpTokenDepositor(params, token0, token1, token0_ComposeMsg, token1_ComposeMsg, depositorsBridged, totals);
        }

        // Ensure that at least one depositor was included in the bridge payload
        require(totals.token0_TotalAmountToBridge > 0 && totals.token1_TotalAmountToBridge > 0, MustBridgeAtLeastOneDepositor());

        uint256 numDepositorsIncluded = params.numDepositorsIncluded;
        // Ensure that the number of depositors bridged is less than the globally defined limit
        require(numDepositorsIncluded <= MAX_INDIVIDUAL_DEPOSITORS_PER_BRIDGE, DepositorsPerBridgeLimitExceeded());
        // Resize the compose messages to reflect the actual number of depositors bridged
        token0_ComposeMsg.resizeComposeMsg(numDepositorsIncluded);
        token1_ComposeMsg.resizeComposeMsg(numDepositorsIncluded);

        // Resize depositors bridged array to reflect the actual number of depositors bridged
        assembly ("memory-safe") {
            mstore(depositorsBridged, numDepositorsIncluded)
        }

        // Create bridge parameters
        LpBridgeParams memory bridgeParams = LpBridgeParams({
            marketHash: _marketHash,
            token0: token0,
            token1: token1,
            totals: totals,
            token0_ComposeMsg: token0_ComposeMsg,
            token1_ComposeMsg: token1_ComposeMsg,
            depositorsBridged: depositorsBridged
        });

        // Execute 2 consecutive bridges for each constituent token
        _executeConsecutiveBridges(bridgeParams);
    }

    /**
     * @notice Let the DepositLocker receive native assets directly.
     * @dev Primarily used for receiving native assets after unwrapping the native asset token.
     */
    receive() external payable { }

    /*//////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Processes a single token depositor by updating the compose message and clearing depositor data.
     * @dev Updates the compose message with the depositor's information if the deposit amount is valid.
     * @param _marketHash The hash of the market to process.
     * @param _depositorIndex The index of the depositor in the batch of depositors.
     * @param _depositor The address of the depositor.
     * @param _ccdmNonce The CCDM nonce for this bridge transaction.
     * @param _composeMsg The current compose message to be updated.
     */
    function _processSingleTokenDepositor(
        bytes32 _marketHash,
        uint256 _depositorIndex,
        address _depositor,
        uint256 _ccdmNonce,
        bytes memory _composeMsg
    )
        internal
        returns (uint256 depositAmount)
    {
        // Get amount deposited by the depositor (AP)
        depositAmount = marketHashToDepositorToIndividualDepositorInfo[_marketHash][_depositor].totalAmountDeposited;

        if (depositAmount == 0 || depositAmount > type(uint96).max) {
            return 0; // Skip if no deposit or deposit amount exceeds limit
        }

        // Mark the current CCDM nonce as the latest CCDM bridge txn that this depositor was included in for this market.
        marketHashToDepositorToIndividualDepositorInfo[_marketHash][_depositor].latestCcdmNonce = _ccdmNonce;

        // Set the total amount deposited by this depositor (AP) for this market to zero
        delete marketHashToDepositorToIndividualDepositorInfo[_marketHash][_depositor].totalAmountDeposited;

        // Add depositor to the compose message
        _composeMsg.writeDepositor(_depositorIndex, _depositor, uint96(depositAmount));
    }

    /**
     * @notice Processes a Uniswap V2 LP token depositor by adjusting for bridge precision, refunding dust, and updating compose messages.
     * @dev Calculates the depositor's prorated share of the underlying tokens, adjusts amounts to match OFT bridge precision using the provided decimal
     * conversion rates,
     *      refunds any residual amounts (dust) back to the depositor, clears depositor data, and updates the compose messages.
     * @param params The parameters required for processing the LP token depositor.
     * @param _token0 The ERC20 instance of Token A.
     * @param _token1 The ERC20 instance of Token B.
     * @param _token0_ComposeMsg The compose message for Token A to be updated.
     * @param _token1_ComposeMsg The compose message for Token B to be updated.
     * @param _depositorsBridged The array of actual depositors included in this bridge.
     * @param _totals The totals for Token A and Token B to be updated.
     */
    function _processLpTokenDepositor(
        LpTokenDepositorParams memory params,
        ERC20 _token0,
        ERC20 _token1,
        bytes memory _token0_ComposeMsg,
        bytes memory _token1_ComposeMsg,
        address[] memory _depositorsBridged,
        TotalAmountsToBridge memory _totals
    )
        internal
    {
        // Calculate the depositor's share of each underlying token
        uint256 token0_DepositAmount = (params.token0_TotalAmountReceivedOnBurn * params.lpToken_DepositAmount) / params.lp_TotalAmountToBridge;
        uint256 token1_DepositAmount = (params.token1_TotalAmountReceivedOnBurn * params.lpToken_DepositAmount) / params.lp_TotalAmountToBridge;

        if (token0_DepositAmount > type(uint96).max || token1_DepositAmount > type(uint96).max) {
            // If can't bridge this depositor, refund their redeemed tokens + fees accrued from LPing
            _token0.safeTransfer(params.depositor, token0_DepositAmount);
            _token1.safeTransfer(params.depositor, token1_DepositAmount);
            return;
        }

        // Adjust depositor amounts to acceptable precision and refund dust if conversion from LD to SD is needed
        if (params.token0_DecimalConversionRate != 1) {
            token0_DepositAmount = _adjustForPrecisionAndRefundDust(params.depositor, _token0, token0_DepositAmount, params.token0_DecimalConversionRate);
        }
        if (params.token1_DecimalConversionRate != 1) {
            token1_DepositAmount = _adjustForPrecisionAndRefundDust(params.depositor, _token1, token1_DepositAmount, params.token1_DecimalConversionRate);
        }

        if (token0_DepositAmount == 0 || token1_DepositAmount == 0) {
            // Can't bridge this depositor because they were trying to bridge a dust amount of at least one token.
            // Refund the non-dust if any and omit from the payload
            if (token0_DepositAmount != 0) {
                _token0.safeTransfer(params.depositor, token0_DepositAmount);
            }
            if (token1_DepositAmount != 0) {
                _token1.safeTransfer(params.depositor, token1_DepositAmount);
            }
            return;
        }

        // Update compose messages with acceptable amounts
        _token0_ComposeMsg.writeDepositor(params.numDepositorsIncluded, params.depositor, uint96(token0_DepositAmount));
        _token1_ComposeMsg.writeDepositor(params.numDepositorsIncluded, params.depositor, uint96(token1_DepositAmount));

        // Update totals
        _totals.token0_TotalAmountToBridge += token0_DepositAmount;
        _totals.token1_TotalAmountToBridge += token1_DepositAmount;

        // Add depositor to depositors bridged array
        _depositorsBridged[params.numDepositorsIncluded++] = params.depositor;
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
        // Get the dust amount based on conversion rate
        uint256 dustAmount = _amountLD % _decimalConversionRate;

        // Refund any dust to the depositor
        if (dustAmount > 0) {
            _token.safeTransfer(_depositor, dustAmount);
        }

        // Subtract dust from deposit amount to get the acceptable amount to bridge for this depositor
        acceptableAmountLD = _amountLD - dustAmount;
    }

    /**
     * @notice Bridges two tokens consecutively to the destination chain using LayerZero's OFT.
     * @dev Handles the bridging of Token A and Token B, fee management, and event emission.
     * @param _params The parameters required for bridging LP tokens.
     */
    function _executeConsecutiveBridges(LpBridgeParams memory _params) internal {
        uint256 totalBridgingFee = 0;
        uint128 destinationGasLimit = CCDMFeeLib.estimateIndividualDepositorsBridgeGasLimit(_params.depositorsBridged.length);

        // Bridge Token A
        MessagingReceipt memory token0_MessageReceipt =
            _executeBridge(_params.token0, _params.totals.token0_TotalAmountToBridge, _params.token0_ComposeMsg, totalBridgingFee, destinationGasLimit);
        totalBridgingFee += token0_MessageReceipt.fee.nativeFee;

        // Bridge Token B
        MessagingReceipt memory token1_MessageReceipt =
            _executeBridge(_params.token1, _params.totals.token1_TotalAmountToBridge, _params.token1_ComposeMsg, totalBridgingFee, destinationGasLimit);
        totalBridgingFee += token1_MessageReceipt.fee.nativeFee;

        // Refund excess value sent with the transaction
        if (msg.value > totalBridgingFee) {
            (bool success,) = payable(msg.sender).call{ value: msg.value - totalBridgingFee }("");
            require(success, RefundFailed());
        }

        // Emit event to keep track of bridged deposits
        emit LpTokensBridgedToDestination(
            _params.marketHash,
            ccdmNonce++,
            _params.depositorsBridged,
            token0_MessageReceipt.guid,
            token0_MessageReceipt.nonce,
            _params.token0,
            _params.totals.token0_TotalAmountToBridge,
            token1_MessageReceipt.guid,
            token1_MessageReceipt.nonce,
            _params.token1,
            _params.totals.token1_TotalAmountToBridge
        );
    }

    /**
     * @notice Bridges LayerZero V2 OFT tokens.
     * @dev Prepares the SendParam internally to optimize for gas and readability.
     * @param _token The token to bridge.
     * @param _amountToBridge The amount of the token to bridge.
     * @param _composeMsg The compose message for the bridge.
     * @param _feesAlreadyPaid The amount of fees already paid in this transaction prior to this bridge.
     * @param _executorGasLimit The gas limit for the executor.
     * @return messageReceipt The messaging receipt from the bridge operation.
     */
    function _executeBridge(
        ERC20 _token,
        uint256 _amountToBridge,
        bytes memory _composeMsg,
        uint256 _feesAlreadyPaid,
        uint128 _executorGasLimit
    )
        internal
        returns (MessagingReceipt memory messageReceipt)
    {
        // Prepare SendParam for bridging
        SendParam memory sendParam = SendParam({
            dstEid: dstChainLzEid,
            to: _addressToBytes32(depositExecutor),
            amountLD: _amountToBridge,
            minAmountLD: _amountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _executorGasLimit, 0),
            composeMsg: _composeMsg,
            oftCmd: ""
        });

        // Get the LayerZero V2 OFT for the token
        IOFT lzV2OFT = tokenToLzV2OFT[_token];

        // Get fee quote for bridging
        MessagingFee memory messagingFee = lzV2OFT.quoteSend(sendParam, false);
        require(msg.value - _feesAlreadyPaid >= messagingFee.nativeFee, InsufficientValueForBridgeFee());

        // Var to store the LZ V2 OFT bridgiing receipt
        OFTReceipt memory bridgeReceipt;

        if (lzV2OFT.token() == address(0)) {
            // If OFT expects native token, unwrap the wrapped native asset tokens
            WRAPPED_NATIVE_ASSET_TOKEN.withdraw(_amountToBridge);

            // Execute the bridge transaction by sending native assets + bridging fee
            (messageReceipt, bridgeReceipt) = lzV2OFT.send{ value: messagingFee.nativeFee + _amountToBridge }(sendParam, messagingFee, address(this));
        } else {
            // Approve the lzV2OFT to bridge tokens
            _token.safeApprove(address(lzV2OFT), _amountToBridge);

            // Execute the bridge transaction
            (messageReceipt, bridgeReceipt) = lzV2OFT.send{ value: messagingFee.nativeFee }(sendParam, messagingFee, address(this));
        }

        // Ensure that all deposits were bridged
        require(bridgeReceipt.amountReceivedLD == _amountToBridge, FailedToBridgeAllDeposits());
    }

    /**
     * @notice Sets the LayerZero V2 OFT for its underlying token.
     * @dev NOTE: _lzV2OFT must implement IOFT.
     * @param _lzV2OFT LayerZero OFT to use to bridge the underlying token.
     */
    function _setLzV2OFTForToken(IOFT _lzV2OFT) internal {
        address underlyingTokenAddress = _lzV2OFT.token();
        // Get the underlying token for this OFT
        ERC20 underlyingToken = underlyingTokenAddress == address(0) ? ERC20(address(WRAPPED_NATIVE_ASSET_TOKEN)) : ERC20(underlyingTokenAddress);
        // Set the LZ V2 OFT for the underlying token
        tokenToLzV2OFT[underlyingToken] = _lzV2OFT;
        emit LzV2OFTForTokenSet(address(underlyingToken), address(_lzV2OFT));
    }

    /**
     * @notice Sets a new owner of the market's corresponding deposit campaign.
     * @param _marketHash The hash of the market for which to set the deposit campaign owner for.
     * @param _campaignOwner The address of the owner of the market's corresponding deposit campaign.
     */
    function _setCampaignOwner(bytes32 _marketHash, address _campaignOwner) internal {
        marketHashToCampaignOwner[_marketHash] = _campaignOwner;
        emit CampaignOwnerSet(_marketHash, _campaignOwner);
    }

    /**
     * @notice Checks if a given token address is a Uniswap V2 LP token.
     * @param _token The address of the token to check.
     * @return True if the token is a Uniswap V2 LP token, false otherwise.
     */
    function _isUniV2Pair(address _token) internal view returns (bool) {
        bytes32 codeHash;
        assembly ("memory-safe") {
            codeHash := extcodehash(_token)
        }
        return (codeHash == UNISWAP_V2_PAIR_CODE_HASH);
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
     * @dev Only callable by the contract owner.
     * @param _dstChainLzEid LayerZero endpoint ID for the destination chain.
     */
    function setDestinationChainEid(uint32 _dstChainLzEid) external onlyOwner {
        dstChainLzEid = _dstChainLzEid;
        emit DestinationChainLzEidSet(_dstChainLzEid);
    }

    /**
     * @notice Sets the DepositExecutor address.
     * @dev Only callable by the contract owner.
     * @param _depositExecutor Address of the new DepositExecutor on the destination chain.
     */
    function setDepositExecutor(address _depositExecutor) external onlyOwner {
        depositExecutor = _depositExecutor;
        emit DepositExecutorSet(_depositExecutor);
    }

    /**
     * @notice Sets owners for the specified campaigns.
     * @dev Only callable by the contract owner.
     * @param _marketHashes The hashes of the markets for which to set the deposit campaign owners for.
     * @param _campaignOwners The addresses of the owners of the markets' corresponding deposit campaigns.
     */
    function setCampaignOwners(bytes32[] calldata _marketHashes, address[] calldata _campaignOwners) external onlyOwner {
        // Make sure the each campaign identified by its source market hash has a corresponding owner
        require(_marketHashes.length == _campaignOwners.length, ArrayLengthMismatch());

        for (uint256 i = 0; i < _marketHashes.length; ++i) {
            _setCampaignOwner(_marketHashes[i], _campaignOwners[i]);
        }
    }

    /**
     * @notice Sets a new owner for the specified campaign.
     * @dev Only callable by the contract owner or the current owner of the campaign.
     * @param _marketHash The hash of the market for which to set the deposit campaign owner for.
     * @param _campaignOwner The address of the owner of the market's corresponding deposit campaign.
     */
    function setNewCampaignOwner(bytes32 _marketHash, address _campaignOwner) external onlyCampaignOwnerOrDepositLockerOwner(_marketHash) {
        _setCampaignOwner(_marketHash, _campaignOwner);
    }

    /**
     * @notice Sets the LayerZero V2 OFTs for the underlying tokens.
     * @notice Elements of _lzV2OFTs must implement IOFT.
     * @dev Only callable by the contract owner.
     * @param _lzV2OFTs LayerZero OFTs to use to bridge the underlying tokens.
     */
    function setLzOFTs(IOFT[] calldata _lzV2OFTs) external onlyOwner {
        for (uint256 i = 0; i < _lzV2OFTs.length; ++i) {
            _setLzV2OFTForToken(_lzV2OFTs[i]);
        }
    }

    /**
     * @notice Removes the LayerZero V2 OFT for the underlying token.
     * @dev Only callable by the contract owner.
     * @param _underlyingToken The underlying token of the LZ V2 OFT to remove.
     */
    function removeLzOFT(ERC20 _underlyingToken) external onlyOwner {
        // Remove the LZ V2 OFT for the underlying token
        delete tokenToLzV2OFT[_underlyingToken];
        emit LzV2OFTForTokenRemoved(address(_underlyingToken));
    }

    /**
     * @notice Sets the global green lighter.
     * @dev Only callable by the contract owner.
     * @param _greenLighter The address of the green lighter responsible for marking deposits as bridgeable for specific markets.
     */
    function setGreenLighter(address _greenLighter) external onlyOwner {
        greenLighter = _greenLighter;
        emit GreenLighterSet(_greenLighter);
    }

    /**
     * @notice Halt deposits and bridging for the specified market.
     * @dev Only callable by the contract owner.
     * @dev NOTE: Halting a market's deposit and bridging is immutable. Withdrawals for that market will still be functional.
     * @param _marketHash The market hash to halt deposits and bridging for.
     */
    function haltMarket(bytes32 _marketHash) external onlyOwner {
        marketHashToHalted[_marketHash] = true;
        emit MarketHalted(_marketHash);
    }

    /**
     * @notice Turns the green light on for a market.
     * @notice Will trigger the 48-hour rage quit duration, after which funds will be bridgable for this market.
     * @dev Only callable by the green lighter.
     * @param _marketHash The market hash to turn the green light on for.
     */
    function turnGreenLightOn(bytes32 _marketHash) external onlyGreenLighter {
        uint256 bridgingAllowedTimestamp = block.timestamp + RAGE_QUIT_PERIOD_DURATION;
        marketHashToBridgingAllowedTimestamp[_marketHash] = bridgingAllowedTimestamp;
        emit GreenLightTurnedOn(_marketHash, bridgingAllowedTimestamp);
    }

    /**
     * @notice Turns the green light off for a market.
     * @notice Will render funds unbridgeable for this market.
     * @dev Only callable by the green lighter.
     * @param _marketHash The market hash to turn the green light off for.
     */
    function turnGreenLightOff(bytes32 _marketHash) external onlyGreenLighter {
        delete marketHashToBridgingAllowedTimestamp[_marketHash];
        emit GreenLightTurnedOff(_marketHash);
    }
}
