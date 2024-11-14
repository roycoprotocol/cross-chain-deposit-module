// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { ILayerZeroComposer } from "src/interfaces/ILayerZeroComposer.sol";
import { IWETH } from "src/interfaces/IWETH.sol";
import { ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { ClonesWithImmutableArgs } from "@clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import { IOFT } from "src/interfaces/IOFT.sol";
import { OFTComposeMsgCodec } from "src/libraries/OFTComposeMsgCodec.sol";
import { DepositType, DepositPayloadLib } from "src/libraries/DepositPayloadLib.sol";

/// @title DepositExecutor
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A singleton contract for receiving and deploying bridged deposits on the destination chain for all deposit campaigns.
/// @notice This contract implements ILayerZeroComposer to execute logic based on the compose messages sent from the source chain.
contract DepositExecutor is ILayerZeroComposer, Ownable2Step, ReentrancyGuardTransient {
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;
    using DepositPayloadLib for bytes;

    /*//////////////////////////////////////////////////////////////
                                   Structures
    //////////////////////////////////////////////////////////////*/

    /// @dev Represents a recipe containing Weiroll commands and state.
    /// @custom:field weirollCommands The weiroll script executed on a depositor's Weiroll Wallet.
    /// @custom:field weirollState State of the Weiroll VM, necessary for executing the Weiroll script.
    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    /// @dev Represents a Deposit Campaign on the destination chain.
    /// @custom:field unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign.
    /// @custom:field depositRecipe The Weiroll Recipe executed on deposit (specified by the owner of the campaign).
    /// @custom:field withdrawalRecipe The Weiroll Recipe executed on withdrawal (specified by the owner of the campaign).
    struct DepositCampaign {
        uint256 unlockTimestamp;
        Recipe depositRecipe;
        Recipe withdrawalRecipe;
    }

    /// @dev Struct to group variables used in dual token bridge processing.
    struct DepositorData {
        address depositorAddress;
        uint96 depositAmount;
        address cachedWeirollWallet;
        address weirollWallet;
    }

    /*//////////////////////////////////////////////////////////////
                                State Variables
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the Weiroll wallet implementation used for cloning.
    address public immutable WEIROLL_WALLET_IMPLEMENTATION;

    /// @notice The address of the LayerZero V2 Endpoint contract on the destination chain.
    address public immutable LAYER_ZERO_V2_ENDPOINT;

    /// @notice The wrapped native asset token on the destination chain.
    address public immutable WRAPPED_NATIVE_ASSET_TOKEN;

    /// @notice The address of the script verifier responsible for verifying scripts before execution.
    address public SCRIPT_VERIFIER;

    /// @dev Mapping from a source market hash to its owner's address.
    mapping(bytes32 => address) public sourceMarketHashToOwner;

    /// @dev Mapping from a source market hash to its DepositCampaign struct.
    mapping(bytes32 => DepositCampaign) public sourceMarketHashToDepositCampaign;

    /// @dev Mapping from a source market hash to a boolean indicating if scripts have been verified.
    mapping(bytes32 => bool) public sourceMarketHashToScriptsVerifiedFlag;

    /// @dev Mapping from a dual token bridge nonce to a mapping of depositor addresses to Weiroll wallet addresses.
    mapping(uint256 => mapping(address => address)) public nonceToDepositorToWeirollWallet;

    /*//////////////////////////////////////////////////////////////
                               Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when bridged deposits are put in fresh Weiroll Wallets for SINGLE_TOKEN deposits.
    /// @param guid The global unique identifier of the bridge transaction.
    /// @param sourceMarketHash The source market hash of the deposits received.
    /// @param weirollWalletsCreated The addresses of the fresh Weiroll Wallets that were created on destination.
    event ReceivedSingleTokenBridge(bytes32 indexed guid, bytes32 indexed sourceMarketHash, address[] weirollWalletsCreated);

    /// @notice Emitted when bridged deposits are put in fresh Weiroll Wallets for DUAL_OR_LP_TOKEN deposits.
    /// @param guid The global unique identifier of the bridge transaction.
    /// @param sourceMarketHash The source market hash of the deposits received.
    /// @param nonce The nonce associated with this DUAL_OR_LP_TOKEN deposits bridge - not to be confused with the LZ bridge transaction nonce.
    /// @param weirollWalletsCreated The addresses of the fresh Weiroll Wallets that were created on destination (if any)
    event ReceivedDualTokenBridge(bytes32 indexed guid, bytes32 indexed sourceMarketHash, uint256 indexed nonce, address[] weirollWalletsCreated);

    /// @notice Emitted on batch execute of Weiroll Wallet deposits.
    /// @param sourceMarketHash The source market hash of the Weiroll wallets.
    /// @param weirollWalletsExecuted The addresses of the weiroll wallets that executed the market's deposit recipe.
    event WeirollWalletsExecutedDeposits(bytes32 indexed sourceMarketHash, address[] weirollWalletsExecuted);

    /// @notice Emitted when a Weiroll wallet executes a withdrawal.
    /// @param weirollWallet The address of the weiroll wallet that executed the withdrawal recipe.
    event WeirollWalletExecutedWithdrawal(address indexed weirollWallet);

    /// @notice Error emitted when the caller is not the SCRIPT_VERIFIER.
    error OnlyScriptVerifier();

    /// @notice Error emitted when the caller is not the owner of the campaign.
    error OnlyCampaignOwner();

    /// @notice Error emitted when campaign owner trying to execute scripts when unverified.
    error ScriptsAreUnverified();

    /// @notice Error emitted when the caller is not the owner of the Weiroll wallet.
    error NotOwner();

    /// @notice Error emitted when trying to interact with a locked wallet.
    error WalletLocked();

    /// @notice Error emitted when trying to set a campaign's unlock timestamp more than once.
    error CampaignUnlockTimestampCanOnlyBeSetOnce();

    /// @notice Error emitted when the caller of the lzCompose function isn't the LZ endpoint address for destination chain.
    error NotFromLzV2Endpoint();

    /// @notice Error emitted when the caller of the composeMsg instructs the executor to deploy more funds into Weiroll Wallets than were bridged.
    error CannotDepositMoreThanAmountBridged();

    /*//////////////////////////////////////////////////////////////
                                  Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the global SCRIPT_VERIFIER.
    modifier onlyScriptVerifier() {
        require(msg.sender == SCRIPT_VERIFIER, OnlyScriptVerifier());
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the campaign.
    modifier onlyCampaignOwner(bytes32 _sourceMarketHash) {
        require(msg.sender == sourceMarketHashToOwner[_sourceMarketHash], OnlyCampaignOwner());
        _;
    }

    /// @dev Modifier to ensure the campaign's scripts are verified.
    modifier scriptsAreVerified(bytes32 _sourceMarketHash) {
        require(sourceMarketHashToScriptsVerifiedFlag[_sourceMarketHash], ScriptsAreUnverified());
        _;
    }

    /// @dev Modifier to check if the Weiroll wallet is unlocked.
    modifier weirollWalletIsUnlocked(address _weirollWallet) {
        require(WeirollWallet(payable(_weirollWallet)).lockedUntil() <= block.timestamp, WalletLocked());
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the Weiroll wallet.
    modifier isWeirollWalletOwner(address _weirollWallet) {
        require(WeirollWallet(payable(_weirollWallet)).owner() == msg.sender, NotOwner());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the DepositExecutor Contract.
     * @param _owner The address of the owner of this contract.
     * @param _lzV2Endpoint The address of the LayerZero V2 Endpoint on the destination chain.
     * @param _scriptVerifier The address of the script verifier.
     * @param _wrapped_native_asset_token The address of the wrapped native asset token on the destination chain.
     */
    constructor(address _owner, address _lzV2Endpoint, address _scriptVerifier, address _wrapped_native_asset_token) Ownable(_owner) {
        // Deploy the Weiroll Wallet implementation on the destination chain to use for cloning with immutable args
        WEIROLL_WALLET_IMPLEMENTATION = address(new WeirollWallet());
        LAYER_ZERO_V2_ENDPOINT = _lzV2Endpoint;
        SCRIPT_VERIFIER = _scriptVerifier;
        WRAPPED_NATIVE_ASSET_TOKEN = _wrapped_native_asset_token;
    }

    /*//////////////////////////////////////////////////////////////
                              External Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Composes a LayerZero message from an OApp.
     * @dev This function is called by the LayerZero V2 Endpoint when a message is composed.
     * It processes the message and handles the bridging of deposits.
     * @param _from The address initiating the composition (LayerZero OApp).
     * @param _guid The unique identifier for the corresponding LayerZero src/dst transaction.
     * @param _message The composed message payload in bytes.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable nonReentrant {
        // Ensure the caller is the LayerZero V2 Endpoint
        require(msg.sender == LAYER_ZERO_V2_ENDPOINT, NotFromLzV2Endpoint());

        // Extract the compose message from the _message
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);
        uint256 tokenAmountBridged = OFTComposeMsgCodec.amountLD(_message);

        // Extract the DepositType (1 byte) and source market's hash (first 32 bytes)
        (DepositType depositType, bytes32 sourceMarketHash) = composeMsg.readComposeMsgMetadata();

        // Get the deposit token from the LZ V2 OApp that invoked the compose call
        ERC20 depositToken = ERC20(IOFT(_from).token());
        if (address(depositToken) == address(0)) {
            // If the deposit token is the native asset, wrap the native asset, and use the wrapped token as the deposit token
            IWETH(WRAPPED_NATIVE_ASSET_TOKEN).deposit{ value: tokenAmountBridged }();
            depositToken = ERC20(WRAPPED_NATIVE_ASSET_TOKEN);
        }

        if (depositType == DepositType.SINGLE_TOKEN) {
            address[] memory weirollWalletsCreated = _processSingleTokenBridge(
                sourceMarketHash, composeMsg, depositToken, tokenAmountBridged, sourceMarketHashToDepositCampaign[sourceMarketHash].unlockTimestamp
            );

            emit ReceivedSingleTokenBridge(_guid, sourceMarketHash, weirollWalletsCreated);
        } else if (depositType == DepositType.DUAL_OR_LP_TOKEN) {
            // Get the nonce for the DUAL_OR_LP_TOKEN deposits bridge
            uint256 nonce = composeMsg.readNonce();

            // Create and cache the weiroll wallets for subsequent constituent token bridge
            address[] memory weirollWalletsCreated = _processDualTokenBridge(
                sourceMarketHash, nonce, composeMsg, depositToken, tokenAmountBridged, sourceMarketHashToDepositCampaign[sourceMarketHash].unlockTimestamp
            );

            emit ReceivedDualTokenBridge(_guid, sourceMarketHash, nonce, weirollWalletsCreated);
        }
    }

    /**
     * @notice Executes the deposit scripts for the specified Weiroll wallets.
     * @dev Can't execute unless scripts are verified.
     * @param _sourceMarketHash The source market hash of the Weiroll wallets' market.
     * @param _weirollWallets The addresses of the Weiroll wallets.
     */
    function executeDepositRecipes(
        bytes32 _sourceMarketHash,
        address[] calldata _weirollWallets
    )
        external
        onlyCampaignOwner(_sourceMarketHash)
        scriptsAreVerified(_sourceMarketHash)
        nonReentrant
    {
        // Get the campaign's deposit recipe
        Recipe storage depositRecipe = sourceMarketHashToDepositCampaign[_sourceMarketHash].depositRecipe;
        // Execute deposit recipes for specified wallets
        for (uint256 i = 0; i < _weirollWallets.length; ++i) {
            // Only execute deposit if the wallet belongs to this market
            if (WeirollWallet(payable(_weirollWallets[i])).marketHash() == _sourceMarketHash) {
                // Execute the deposit recipe on the Weiroll wallet
                WeirollWallet(payable(_weirollWallets[i])).executeWeiroll(depositRecipe.weirollCommands, depositRecipe.weirollState);
            }
        }
        emit WeirollWalletsExecutedDeposits(_sourceMarketHash, _weirollWallets);
    }

    /**
     * @notice Executes the withdrawal script in the Weiroll wallet.
     * @param _weirollWallet The address of the Weiroll wallet.
     */
    function executeWithdrawalRecipe(address _weirollWallet)
        external
        isWeirollWalletOwner(_weirollWallet)
        weirollWalletIsUnlocked(_weirollWallet)
        nonReentrant
    {
        // Instantiate the WeirollWallet from the wallet address
        WeirollWallet wallet = WeirollWallet(payable(_weirollWallet));

        // Get the source market's hash associated with the Weiroll wallet
        bytes32 sourceMarketHash = wallet.marketHash();

        // Get the withdrawal recipe for the campaign
        Recipe storage withdrawalRecipe = sourceMarketHashToDepositCampaign[sourceMarketHash].withdrawalRecipe;

        // Execute the withdrawal recipe
        wallet.executeWeiroll(withdrawalRecipe.weirollCommands, withdrawalRecipe.weirollState);

        emit WeirollWalletExecutedWithdrawal(_weirollWallet);
    }

    /*//////////////////////////////////////////////////////////////
                              Internal Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates Weiroll wallets for single token deposits and transfers the deposited tokens to them.
     * @dev Processes the compose message to extract depositor addresses and deposit amounts, creates Weiroll wallets for each depositor, and transfers the
     * corresponding deposit amounts to each wallet.
     * @param _sourceMarketHash The market hash from the source chain identifying the deposit campaign.
     * @param _composeMsg The compose message containing depositor information (addresses and deposit amounts).
     * @param _depositToken The ERC20 token that was bridged and will be deposited into the Weiroll wallets.
     * @param _tokenAmountBridged The total amount of tokens that were bridged and available for deposits.
     * @param _campaignUnlockTimestamp The absolute timestamp when the Weiroll wallets can be unlocked.
     * @return weirollWalletsCreated An array of addresses of the Weiroll wallets that were created for the depositors.
     */
    function _processSingleTokenBridge(
        bytes32 _sourceMarketHash,
        bytes memory _composeMsg,
        ERC20 _depositToken,
        uint256 _tokenAmountBridged,
        uint256 _campaignUnlockTimestamp
    )
        internal
        returns (address[] memory weirollWalletsCreated)
    {
        // Keep track of total deposits that the compose message tries to deploy into Weiroll Wallets
        // Used to make sure tokens out <= tokens in
        uint256 amountDeposited = 0;

        // Initialize first depositor offset for SINGLE_TOKEN payload
        uint256 offset = DepositPayloadLib.SINGLE_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET;

        // Num depositors bridged = (bytes for the part of the composeMsg with depositor information / Bytes per depositor)
        uint256 numDepositorsBridged =
            (_composeMsg.length - DepositPayloadLib.SINGLE_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET) / DepositPayloadLib.BYTES_PER_DEPOSITOR;

        // Keep track of weiroll wallets created for event emission (to be used in deposit recipe execution phase)
        weirollWalletsCreated = new address[](numDepositorsBridged);
        uint256 currIndex = 0;

        // Loop through the compose message and process each depositor
        while (offset + DepositPayloadLib.BYTES_PER_DEPOSITOR <= _composeMsg.length) {
            // Extract AP address (20 bytes)
            address depositorAddress = _composeMsg.readAddress(offset);
            offset += 20;

            // Extract deposit amount (12 bytes)
            uint96 depositAmount = _composeMsg.readUint96(offset);
            // Check that the total amount deposited into Weiroll Wallets isn't more than the amount bridged
            amountDeposited += depositAmount;
            require(amountDeposited <= _tokenAmountBridged, CannotDepositMoreThanAmountBridged());
            offset += 12;

            // Deploy the Weiroll wallet for the depositor
            address weirollWallet = _createWeirollWallet(_sourceMarketHash, depositorAddress, depositAmount, _campaignUnlockTimestamp);

            // Transfer the deposited tokens to the Weiroll wallet
            _depositToken.safeTransfer(weirollWallet, depositAmount);

            // Push fresh weiroll wallet to wallets created array
            weirollWalletsCreated[currIndex++] = weirollWallet;
        }
    }

    /**
     * @notice Processes dual token deposits by creating Weiroll wallets and transferring deposited tokens to them.
     * @dev For each depositor in the compose message, this function either creates a new Weiroll wallet or uses an existing one (cached by nonce and depositor
     * address) to transfer the deposited tokens.
     * Ensures that the total amount deposited does not exceed the total amount bridged.
     * @param _sourceMarketHash The market hash from the source chain identifying the deposit campaign.
     * @param _nonce The nonce associated with the dual token bridge, used to cache Weiroll wallets between the two constituent token transfers.
     * @param _composeMsg The compose message containing depositor information (addresses and deposit amounts).
     * @param _depositToken The ERC20 token that was bridged and will be deposited into the Weiroll wallets.
     * @param _tokenAmountBridged The total amount of tokens that were bridged and are available for deposits.
     * @param _campaignUnlockTimestamp The timestamp when the Weiroll wallets can be unlocked.
     * @return weirollWalletsCreated An array of addresses of the Weiroll wallets that were created for the depositors.
     */
    function _processDualTokenBridge(
        bytes32 _sourceMarketHash,
        uint256 _nonce,
        bytes memory _composeMsg,
        ERC20 _depositToken,
        uint256 _tokenAmountBridged,
        uint256 _campaignUnlockTimestamp
    )
        internal
        returns (address[] memory weirollWalletsCreated)
    {
        uint256 amountDeposited = 0;

        // Initialize first depositor offset for DUAL_OR_LP_TOKEN payload
        uint256 offset = DepositPayloadLib.DUAL_OR_LP_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET;

        // Number of depositors bridged
        uint256 numDepositorsBridged =
            (_composeMsg.length - DepositPayloadLib.DUAL_OR_LP_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET) / DepositPayloadLib.BYTES_PER_DEPOSITOR;

        weirollWalletsCreated = new address[](numDepositorsBridged);
        uint256 currIndex = 0;

        while (offset + DepositPayloadLib.BYTES_PER_DEPOSITOR <= _composeMsg.length) {
            // Use struct to group variables
            DepositorData memory depositorData;

            // Extract AP address (20 bytes)
            depositorData.depositorAddress = _composeMsg.readAddress(offset);
            offset += 20;

            // Extract deposit amount (12 bytes)
            depositorData.depositAmount = _composeMsg.readUint96(offset);
            offset += 12;

            // Update total amount deposited
            amountDeposited += depositorData.depositAmount;
            require(amountDeposited <= _tokenAmountBridged, CannotDepositMoreThanAmountBridged());

            // Check if there is a cached wallet for this nonce
            depositorData.cachedWeirollWallet = nonceToDepositorToWeirollWallet[_nonce][depositorData.depositorAddress];

            if (depositorData.cachedWeirollWallet == address(0)) {
                // Create new Weiroll wallet
                depositorData.weirollWallet = _createWeirollWallet(_sourceMarketHash, depositorData.depositorAddress, 0, _campaignUnlockTimestamp);

                // Transfer the deposited tokens to the Weiroll wallet
                _depositToken.safeTransfer(depositorData.weirollWallet, depositorData.depositAmount);

                // Cache the Weiroll wallet for this depositor and nonce
                nonceToDepositorToWeirollWallet[_nonce][depositorData.depositorAddress] = depositorData.weirollWallet;

                // Store the wallet address for event emission
                weirollWalletsCreated[currIndex++] = depositorData.weirollWallet;
            } else {
                // Transfer the deposited tokens to the cached Weiroll Wallet
                _depositToken.safeTransfer(depositorData.cachedWeirollWallet, depositorData.depositAmount);
            }
        }

        // Resize weirollWalletsCreated array if necessary
        if (currIndex < weirollWalletsCreated.length) {
            assembly ("memory-safe") {
                mstore(weirollWalletsCreated, currIndex)
            }
        }
    }

    /**
     * @dev Deploys a Weiroll wallet for the depositor.
     * @param _sourceMarketHash The source market's hash.
     * @param _owner The owner of the Weiroll wallet (AP address).
     * @param _amount The amount deposited.
     * @param _lockedUntil The timestamp until which the wallet is locked.
     * @return weirollWallet The address of the Weiroll wallet.
     */
    function _createWeirollWallet(
        bytes32 _sourceMarketHash,
        address _owner,
        uint256 _amount,
        uint256 _lockedUntil
    )
        internal
        returns (address payable weirollWallet)
    {
        // Deploy a new non-forfeitable Weiroll Wallet with immutable args
        bytes memory weirollParams = abi.encodePacked(_owner, address(this), _amount, _lockedUntil, false, _sourceMarketHash);
        weirollWallet = payable(WEIROLL_WALLET_IMPLEMENTATION.clone(weirollParams));
    }

    /*//////////////////////////////////////////////////////////////
                            Administrative Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the script verifier address.
     * @param _scriptVerifier The address of the script verifier.
     */
    function setVerifier(address _scriptVerifier) external onlyOwner {
        SCRIPT_VERIFIER = _scriptVerifier;
    }

    /**
     * @notice Sets the owner of a source market (identified by its hash) and its corresponding Deposit Campaign.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _owner The address of the campaign owner.
     */
    function setSourceMarketOwner(bytes32 _sourceMarketHash, address _owner) external onlyOwner {
        sourceMarketHashToOwner[_sourceMarketHash] = _owner;
    }

    /**
     * @notice Sets the scripts to verified (now they are executable) for a campaign identified by _sourceMarketHash.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _scriptVerified Boolean indicating whether or not the script is verified.
     */
    function setScriptVerificationStatus(bytes32 _sourceMarketHash, bool _scriptVerified) external onlyScriptVerifier {
        sourceMarketHashToScriptsVerifiedFlag[_sourceMarketHash] = _scriptVerified;
    }

    /**
     * @notice Sets a new owner for the specified campaign.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _newOwner The address of the new campaign owner.
     */
    function setNewCampaignOwner(bytes32 _sourceMarketHash, address _newOwner) external onlyCampaignOwner(_sourceMarketHash) {
        sourceMarketHashToOwner[_sourceMarketHash] = _newOwner;
    }

    /**
     * @notice Sets the unlock timestamp for a Deposit Campaign.
     * @dev The unlock timestamp can only be set once per campaign.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign.
     */
    function setCampaignUnlockTimestamp(bytes32 _sourceMarketHash, uint256 _unlockTimestamp) external onlyCampaignOwner(_sourceMarketHash) {
        require(sourceMarketHashToDepositCampaign[_sourceMarketHash].unlockTimestamp == 0, CampaignUnlockTimestampCanOnlyBeSetOnce());
        sourceMarketHashToDepositCampaign[_sourceMarketHash].unlockTimestamp = _unlockTimestamp;
    }

    /**
     * @notice Sets the deposit recipe for a Deposit Campaign.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _depositRecipe The deposit recipe for the campaign on the destination chain.
     */
    function setCampaignDepositRecipe(bytes32 _sourceMarketHash, Recipe calldata _depositRecipe) external onlyCampaignOwner(_sourceMarketHash) {
        sourceMarketHashToDepositCampaign[_sourceMarketHash].depositRecipe = _depositRecipe;
        delete sourceMarketHashToScriptsVerifiedFlag[_sourceMarketHash];
    }

    /**
     * @notice Sets the withdrawal recipe for a Deposit Campaign.
     * @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
     * @param _withdrawalRecipe The withdrawal recipe for the campaign on the destination chain.
     */
    function setCampaignWithdrawalRecipe(bytes32 _sourceMarketHash, Recipe calldata _withdrawalRecipe) external onlyCampaignOwner(_sourceMarketHash) {
        sourceMarketHashToDepositCampaign[_sourceMarketHash].withdrawalRecipe = _withdrawalRecipe;
        delete sourceMarketHashToScriptsVerifiedFlag[_sourceMarketHash];
    }
}
