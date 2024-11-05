// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { ILayerZeroComposer } from "src/interfaces/ILayerZeroComposer.sol";
import { ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { ClonesWithImmutableArgs } from "@clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import { IOFT } from "src/interfaces/IOFT.sol";
import { OFTComposeMsgCodec } from "src/libraries/OFTComposeMsgCodec.sol";
import { DepositType, DepositPayloadLib } from "src/libraries/DepositPayloadLib.sol";

/// @title DepositExecutor
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A singleton contract for receiving and deploying bridged deposits on the destination chain for all deposit campaigns.
/// @notice This contract implements ILayerZeroComposer to act on compose messages sent from the source chain.
contract DepositExecutor is ILayerZeroComposer, Ownable2Step, ReentrancyGuardTransient {
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;
    using DepositPayloadLib for bytes;

    /*//////////////////////////////////////////////////////////////
                               Structures
    //////////////////////////////////////////////////////////////*/

    /// @dev Represents a recipe containing Weiroll commands and state.
    /// @custom:field weirollCommands The weiroll script executed on an depositor's Weiroll Wallet.
    /// @custom:field weirollState State of the Weiroll VM, necessary for executing the Weiroll script.
    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    /// @dev Represents a SINGLE_TOKEN Deposit Campaign on the destination chain.
    /// @custom:field dstDepositToken The deposit token for the campaign on the destination chain.
    /// @custom:field unlockTimestamp  The ABSOLUTE timestamp until deposits will be locked for this campaign.
    /// @custom:field depositRecipe The Weiroll recipe executed on deposit (specified by the owner of the campaign).
    /// @custom:field withdrawalRecipe The Weiroll recipe executed on withdrawal (specified by the owner of the campaign).
    struct SingleTokenDepositCampaign {
        ERC20 dstDepositToken;
        uint256 unlockTimestamp;
        Recipe depositRecipe;
        Recipe withdrawalRecipe;
    }

    /// @dev Represents a DUAL_TOKEN Deposit Campaign on the destination chain.
    /// @custom:field dstDepositTokenA Token A on the destination chain for a DUAL_TOKEN campaign.
    /// @custom:field dstDepositTokenB Token B on the destination chain for a DUAL_TOKEN campaign.
    /// @custom:field unlockTimestamp  The ABSOLUTE timestamp until deposits will be locked for this campaign.
    /// @custom:field depositRecipe The Weiroll recipe executed on deposit (specified by the owner of the campaign).
    /// @custom:field withdrawalRecipe The Weiroll recipe executed on withdrawal (specified by the owner of the campaign).
    struct DualTokenDepositCampaign {
        ERC20 dstDepositTokenA;
        ERC20 dstDepositTokenB;
        uint256 unlockTimestamp;
        Recipe depositRecipe;
        Recipe withdrawalRecipe;
    }

    /*//////////////////////////////////////////////////////////////
                            State Variables
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the Weiroll wallet implementation on the destination chain.
    address public immutable WEIROLL_WALLET_IMPLEMENTATION;

    /// @notice The address of the LayerZero V2 Endpoint on the destination chain.
    address public lzV2Endpoint;

    /// @notice Mapping of an ERC20 token to its corresponding LayerZero OFT (Native OFT, OFT Adapter, Stargate Pool, Stargate Hydra, etc.)
    /// @dev Must implement the IOFT interface.
    mapping(ERC20 => address) public tokenToLzV2OFT;

    /// @dev Mapping from a market hash on the source chain to its owner's address.
    mapping(bytes32 => address) public sourceMarketHashToOwner;

    /// @dev Mapping from a market hash on the source chain to its SingleTokenDepositCampaign struct.
    mapping(bytes32 => SingleTokenDepositCampaign) public sourceMarketHashToSingleTokenDepositCampaign;

    /// @dev Mapping from a market hash on the source chain to its SingleTokenDepositCampaign struct.
    mapping(bytes32 => DualTokenDepositCampaign) public sourceMarketHashToDualTokenDepositCampaign;

    /// @dev Mapping from a DUAL_TOKEN bridge nonce to the depositor address to the address of the weiroll wallet created upon bridging the first constituent
    mapping(uint256 => mapping(address => address)) public nonceToDepositorToWeirollWallet;

    /*//////////////////////////////////////////////////////////////
                           Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when bridged deposits are put in fresh Weiroll Wallets for SINGLE_TOKEN deposits.
    /// @param guid The global unique identifier of the bridge transaction.
    /// @param sourceMarketHash The source market hash of the deposits received.
    /// @param weirollWalletsCreated The addresses of the fresh Weiroll Wallets that were created on destination.
    event FreshWeirollWalletsCreatedForSingleTokenDeposits(bytes32 indexed guid, bytes32 indexed sourceMarketHash, address[] weirollWalletsCreated);

    /// @notice Emitted when bridged deposits are put in fresh Weiroll Wallets for DUAL_TOKEN deposits.
    /// @param guid The global unique identifier of the bridge transaction.
    /// @param sourceMarketHash The source market hash of the deposits received.
    /// @param nonce The nonce associated with this DUAL_TOKEN deposits bridge - not to be confused with the LZ bridge transaction nonce.
    /// @param weirollWalletsCreated The addresses of the fresh Weiroll Wallets that were created on destination.
    event FreshWeirollWalletsCreatedForDualTokenDeposits(
        bytes32 indexed guid, bytes32 indexed sourceMarketHash, uint256 indexed nonce, address[] weirollWalletsCreated
    );

    /// @notice Emitted when both constituent tokens are in the Weiroll Wallets for DUAL_TOKEN deposits of a specific nonce.
    /// @param guid The global unique identifier of the bridge transaction.
    /// @param sourceMarketHash The source market hash of the deposits received.
    /// @param nonce The nonce associated with this DUAL_TOKEN deposits bridge.
    event DualTokenDepositsCompleted(bytes32 indexed guid, bytes32 indexed sourceMarketHash, uint256 indexed nonce);

    /// @notice Emitted when a Weiroll wallet executes a deposit.
    /// @param weirollWallet The address of the weiroll wallet that executed the deposit recipe.
    event WeirollWalletExecutedDeposit(address indexed weirollWallet);

    /// @notice Emitted on batch execute of Weiroll Wallet deposits.
    /// @param sourceMarketHash The source market hash of the Weiroll Wallets.
    /// @param weirollWallets The addresses of the weiroll wallets that executed the market's deposit recipe.
    event WeirollWalletsExecutedDeposits(bytes32 indexed sourceMarketHash, address[] weirollWallets);

    /// @notice Emitted when a Weiroll wallet executes a withdrawal.
    /// @param weirollWallet The address of the weiroll wallet that executed the withdrawal recipe.
    event WeirollWalletExecutedWithdrawal(address indexed weirollWallet);

    /// @notice Error emitted when the caller is not the owner of the campaign.
    error OnlyOwnerOfSingleTokenDepositCampaign();

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when setting a lzV2OFT for a token that doesn't match the OApp's underlying token
    error InvalidLzV2OFTForToken();

    /// @notice Error emitted when the caller is not the owner of the Weiroll wallet.
    error NotOwner();

    /// @notice Error emitted when trying to interact with a locked wallet.
    error WalletLocked();

    /// @notice Error emitted when trying to execute deposit recipe more than once.
    error DepositRecipeAlreadyExecuted();

    /// @notice Error emitted when the caller of the lzCompose function isn't the LZ endpoint address for destination chain.
    error NotFromLzV2Endpoint();

    /// @notice Error emitted when the caller of the composeMsg instructs the executor to deploy more funds into Weiroll Wallets than were bridged
    error CantDepositMoreThanAmountBridged();

    /// @notice Error emitted when the _from in the lzCompose function isn't the correct LayerZero OApp address.
    error NotFromLzV2OFT();

    /// @notice Error emitted when reading from bytes array is out of bounds.
    error EOF();

    /*//////////////////////////////////////////////////////////////
                              Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the owner of the campaign.
    modifier onlyOwnerOfSingleTokenDepositCampaign(bytes32 _sourceMarketHash) {
        require(msg.sender == sourceMarketHashToOwner[_sourceMarketHash], OnlyOwnerOfSingleTokenDepositCampaign());
        _;
    }

    /// @dev Modifier to check if the Weiroll wallet is unlocked.
    modifier weirollIsUnlocked(address _weirollWallet) {
        require(WeirollWallet(payable(_weirollWallet)).lockedUntil() <= block.timestamp, WalletLocked());
        _;
    }

    /// @dev Modifier to check if the Weiroll wallet is unlocked.
    modifier depositRecipeNotExecuted(address _weirollWallet) {
        require(!WeirollWallet(payable(_weirollWallet)).executed(), DepositRecipeAlreadyExecuted());
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the Weiroll wallet.
    modifier isWeirollOwner(address _weirollWallet) {
        require(WeirollWallet(payable(_weirollWallet)).owner() == msg.sender, NotOwner());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the DepositExecutor Contract.
    /// @param _owner The address of the owner of this contract.
    /// @param _weirollWalletImplementation The address of the Weiroll wallet implementation.
    /// @param _lzV2Endpoint The address of the LayerZero V2 Endpoint.
    /// @param _depositTokens The tokens that are bridged to the destination chain from the source chain. (dest chain addresses)
    /// @param _lzV2OFTs The corresponding LayerZero OApp instances for each deposit token on the destination chain.
    constructor(
        address _owner,
        address _weirollWalletImplementation,
        address _lzV2Endpoint,
        ERC20[] memory _depositTokens,
        address[] memory _lzV2OFTs
    )
        Ownable(_owner)
    {
        require(_depositTokens.length == _lzV2OFTs.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _depositTokens.length; ++i) {
            // Get the underlying token for this OFT
            address underlyingToken = IOFT(_lzV2OFTs[i]).token();
            // Check that the underlying token is the specified token or the chain's native asset
            require(underlyingToken == address(_depositTokens[i]) || underlyingToken == address(0), InvalidLzV2OFTForToken());
            tokenToLzV2OFT[_depositTokens[i]] = _lzV2OFTs[i];
        }

        WEIROLL_WALLET_IMPLEMENTATION = _weirollWalletImplementation;
        lzV2Endpoint = _lzV2Endpoint;
    }

    /*//////////////////////////////////////////////////////////////
                          External Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new SINGLE_TOKEN deposit campaign with the specified parameters.
    /// @param _sourceMarketHash The unique identifier for the campaign.
    /// @param _owner The address of the campaign owner.
    /// @param _dstDepositToken The ERC20 token used as input for the campaign.
    function createSingleTokenDepositCampaign(bytes32 _sourceMarketHash, address _owner, ERC20 _dstDepositToken) external onlyOwner {
        sourceMarketHashToOwner[_sourceMarketHash] = _owner;
        sourceMarketHashToSingleTokenDepositCampaign[_sourceMarketHash].dstDepositToken = _dstDepositToken;
    }

    /// @notice Sets the LayerZero V2 Endpoint address for this chain.
    /// @param _newLzV2Endpoint New LayerZero V2 Endpoint for this chain
    function setLzEndpoint(address _newLzV2Endpoint) external onlyOwner {
        lzV2Endpoint = _newLzV2Endpoint;
    }

    /// @notice Sets the LayerZero Omnichain App instance for a given token.
    /// @param _token Token to set the LayerZero Omnichain App for.
    /// @param _lzV2OFT LayerZero OFT to use to bridge the specified token.
    function setLzV2OFTForToken(ERC20 _token, address _lzV2OFT) external onlyOwner {
        // Get the underlying token for this OFT
        address underlyingToken = IOFT(_lzV2OFT).token();
        // Check that the underlying token is the specified token or the chain's native asset
        require(underlyingToken == address(_token) || underlyingToken == address(0), InvalidLzV2OFTForToken());
        tokenToLzV2OFT[_token] = _lzV2OFT;
    }

    /// @notice Sets a new owner for the specified campaign.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _newOwner The address of the new campaign owner.
    function setSingleTokenDepositCampaignOwner(
        bytes32 _sourceMarketHash,
        address _newOwner
    )
        external
        onlyOwnerOfSingleTokenDepositCampaign(_sourceMarketHash)
    {
        sourceMarketHashToOwner[_sourceMarketHash] = _newOwner;
    }

    /// @notice Sets the ABSOLUTE timestamp until deposits will be locked for this campaign on destination.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign on destination.
    function setSingleTokenDepositCampaignUnlockTimestamp(
        bytes32 _sourceMarketHash,
        uint256 _unlockTimestamp
    )
        external
        onlyOwnerOfSingleTokenDepositCampaign(_sourceMarketHash)
    {
        sourceMarketHashToSingleTokenDepositCampaign[_sourceMarketHash].unlockTimestamp = _unlockTimestamp;
    }

    /// @notice Sets the deposit recipe for a SingleTokenDepositCampaign.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _depositRecipe The deposit recipe for the campaign on the destination chain.
    function setSingleTokenDepositRecipe(
        bytes32 _sourceMarketHash,
        Recipe calldata _depositRecipe
    )
        external
        onlyOwnerOfSingleTokenDepositCampaign(_sourceMarketHash)
    {
        sourceMarketHashToSingleTokenDepositCampaign[_sourceMarketHash].depositRecipe = _depositRecipe;
    }

    /// @notice Sets the withdrawal recipe for a SingleTokenDepositCampaign.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _withdrawalRecipe The withdrawal recipe for the campaign on the destination chain.
    function setSingleTokenWithdrawalRecipe(
        bytes32 _sourceMarketHash,
        Recipe calldata _withdrawalRecipe
    )
        external
        onlyOwnerOfSingleTokenDepositCampaign(_sourceMarketHash)
    {
        sourceMarketHashToSingleTokenDepositCampaign[_sourceMarketHash].withdrawalRecipe = _withdrawalRecipe;
    }

    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from The address initiating the composition.
     * @param _guid The unique identifier for the corresponding LayerZero src/dst tx.
     * @param _message The composed message payload in bytes.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable nonReentrant {
        // Ensure the caller is the LayerZero V2 Endpoint
        require(msg.sender == lzV2Endpoint, NotFromLzV2Endpoint());

        // Extract the compose message from the _message
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);
        uint256 tokenAmountBridged = OFTComposeMsgCodec.amountLD(_message);

        // Extract the DepositType (1 byte) source market's hash (first 32 bytes)
        (DepositType depositType, bytes32 sourceMarketHash) = composeMsg.readComposeMsgMetadata();

        if (depositType == DepositType.SINGLE_TOKEN) {
            // Make sure at least one depositor was bridged
            require(composeMsg.length >= DepositPayloadLib.MIN_SINGLE_TOKEN_PAYLOAD_SIZE, EOF());

            // Get the SINGLE_TOKEN deposit campaign
            SingleTokenDepositCampaign storage depositCampaign = sourceMarketHashToSingleTokenDepositCampaign[sourceMarketHash];

            ERC20 depositToken = depositCampaign.dstDepositToken;

            // Ensure that the _from address is the expected LayerZero OFT contract for this token
            require(_from == tokenToLzV2OFT[depositToken], NotFromLzV2OFT());

            address[] memory weirollWalletsCreated =
                _createWeirollWalletsForSingleTokenDeposits(sourceMarketHash, composeMsg, depositToken, tokenAmountBridged, depositCampaign.unlockTimestamp);

            emit FreshWeirollWalletsCreatedForSingleTokenDeposits(_guid, sourceMarketHash, weirollWalletsCreated);
        } else if (depositType == DepositType.DUAL_TOKEN) {
            // Make sure at least one depositor was bridged
            require(composeMsg.length >= DepositPayloadLib.MIN_DUAL_TOKEN_PAYLOAD_SIZE, EOF());

            // Get the nonce for the DUAL_TOKEN deposits bridge
            uint256 nonce = composeMsg.readNonce();

            // Get the DUAL_TOKEN deposit campaign
            DualTokenDepositCampaign storage depositCampaign = sourceMarketHashToDualTokenDepositCampaign[sourceMarketHash];

            // Decipher whether this bridge transaction is for tokenA or tokenB and set the deposit token accordingly
            ERC20 depositToken;
            {
                ERC20 depositTokenA = depositCampaign.dstDepositTokenA;
                ERC20 depositTokenB = depositCampaign.dstDepositTokenB;
                // Ensure that the _from address is the expected LayerZero OFT contract for either tokenA or tokenB
                if (_from == tokenToLzV2OFT[depositTokenA]) {
                    depositToken = depositTokenA;
                } else if (_from == tokenToLzV2OFT[depositTokenB]) {
                    depositToken = depositTokenB;
                } else {
                    revert NotFromLzV2OFT();
                }
            }

            // Check if this is the first constituent being bridged for the DUAL_TOKEN bridge nonce
            bool isFirstBridgeForDualToken =
                nonceToDepositorToWeirollWallet[nonce][composeMsg.readAddress(DepositPayloadLib.DUAL_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET)] == address(0);

            if (isFirstBridgeForDualToken) {
                // Create and cache the weiroll wallets for subsequent constituent token bridge
                address[] memory weirollWalletsCreated = _createWeirollWalletsForDualTokenDeposits(
                    sourceMarketHash, nonce, composeMsg, depositToken, tokenAmountBridged, depositCampaign.unlockTimestamp
                );
                emit FreshWeirollWalletsCreatedForDualTokenDeposits(_guid, sourceMarketHash, nonce, weirollWalletsCreated);
            } else {
                // Send the second constituent tokens to the cached weiroll wallets
                _transferSecondConstituentForDualTokenBridge(nonce, composeMsg, depositToken, tokenAmountBridged);
                emit DualTokenDepositsCompleted(_guid, sourceMarketHash, nonce);
            }
        }
    }

    /// @notice Executes the deposit scripts for the specified Weiroll wallets.
    /// @param _sourceMarketHash The source market hash of the Weiroll wallets' market.
    /// @param _weirollWallets The addresses of the Weiroll wallets.
    function executeDepositRecipes(
        bytes32 _sourceMarketHash,
        address[] calldata _weirollWallets
    )
        external
        onlyOwnerOfSingleTokenDepositCampaign(_sourceMarketHash)
        nonReentrant
    {
        // Executed deposit recipes
        for (uint256 i = 0; i < _weirollWallets.length; ++i) {
            if (WeirollWallet(payable(_weirollWallets[i])).marketHash() == _sourceMarketHash) {
                // Only execute deposit if the wallet belongs to this market
                _executeDepositRecipe(_sourceMarketHash, _weirollWallets[i]);
            }
        }
        emit WeirollWalletsExecutedDeposits(_sourceMarketHash, _weirollWallets);
    }

    /// @notice Executes the deposit script in the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function executeDepositRecipe(address _weirollWallet) external isWeirollOwner(_weirollWallet) nonReentrant {
        _executeDepositRecipe(WeirollWallet(payable(_weirollWallet)).marketHash(), _weirollWallet);
        emit WeirollWalletExecutedDeposit(_weirollWallet);
    }

    /// @notice Executes the withdrawal script in the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function executeWithdrawalRecipe(address _weirollWallet) external isWeirollOwner(_weirollWallet) weirollIsUnlocked(_weirollWallet) nonReentrant {
        _executeWithdrawalRecipe(_weirollWallet);
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
    function _createWeirollWalletsForSingleTokenDeposits(
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
            require(amountDeposited <= _tokenAmountBridged, CantDepositMoreThanAmountBridged());
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
     * @notice Creates Weiroll wallets for dual token deposits, transfers the first constituent tokens, and caches the wallets for the second constituent
     * transfer.
     * @dev Processes the compose message to extract depositor addresses and deposit amounts, creates Weiroll wallets for each depositor, transfers the first
     * constituent tokens to each wallet, and caches the wallet addresses for later transfer of the second constituent tokens.
     * @param _sourceMarketHash The market hash from the source chain identifying the deposit campaign.
     * @param _nonce The unique nonce associated with the dual token bridge, used to match the two constituent token transfers.
     * @param _composeMsg The compose message containing depositor information (addresses and deposit amounts).
     * @param _depositToken The first constituent ERC20 token that was bridged and will be deposited into the Weiroll wallets.
     * @param _tokenAmountBridged The total amount of the first constituent tokens that were bridged and available for deposits.
     * @param _campaignUnlockTimestamp The absolute timestamp when the Weiroll wallets can be unlocked.
     * @return weirollWalletsCreated An array of addresses of the Weiroll wallets that were created for the depositors.
     */
    function _createWeirollWalletsForDualTokenDeposits(
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
        // Keep track of total deposits that the compose message tries to deploy into Weiroll Wallets
        // Used to make sure tokens out <= tokens in
        uint256 amountDeposited = 0;

        // Initialize first depositor offset for DUAL_TOKEN payload
        uint256 offset = DepositPayloadLib.DUAL_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET;

        // Num depositors bridged = (bytes for the part of the composeMsg with depositor information / Bytes per depositor)
        uint256 numDepositorsBridged =
            (_composeMsg.length - DepositPayloadLib.DUAL_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET) / DepositPayloadLib.BYTES_PER_DEPOSITOR;

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
            require(amountDeposited <= _tokenAmountBridged, CantDepositMoreThanAmountBridged());
            offset += 12;

            // Deploy the Weiroll wallet for the depositor
            address weirollWallet = _createWeirollWallet(_sourceMarketHash, depositorAddress, depositAmount, _campaignUnlockTimestamp);

            // Transfer the deposited tokens to the Weiroll wallet
            _depositToken.safeTransfer(weirollWallet, depositAmount);

            // Push fresh weiroll wallet to wallets created array
            weirollWalletsCreated[currIndex++] = weirollWallet;

            // Cache the weiroll wallet to send the second constituent to on subsequent DUAL_TOKEN bridge with the same nonce
            nonceToDepositorToWeirollWallet[_nonce][depositorAddress] = weirollWallet;
        }
    }

    /**
     * @notice Transfers the second constituent tokens for a dual token bridge to the cached Weiroll wallets.
     * @dev Processes the compose message to extract depositor addresses and deposit amounts, retrieves the cached Weiroll wallets using the nonce, transfers
     * the second constituent tokens to each wallet, and clears the cache for the nonce and depositors.
     * @param _nonce The unique nonce associated with the dual token bridge, used to match the two constituent token transfers.
     * @param _composeMsg The compose message containing depositor information (addresses and deposit amounts).
     * @param _depositToken The second constituent ERC20 token that was bridged and will be transferred to the cached Weiroll wallets.
     * @param _tokenAmountBridged The total amount of the second constituent tokens that were bridged and available for deposits.
     */
    function _transferSecondConstituentForDualTokenBridge(
        uint256 _nonce,
        bytes memory _composeMsg,
        ERC20 _depositToken,
        uint256 _tokenAmountBridged
    )
        internal
    {
        // Keep track of total deposits that the compose message tries to deploy into Weiroll Wallets
        // Used to make sure tokens out <= tokens in
        uint256 amountDeposited = 0;

        // Initialize first depositor offset for DUAL_TOKEN payload
        uint256 offset = DepositPayloadLib.DUAL_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET;

        // Loop through the compose message and process each depositor
        while (offset + DepositPayloadLib.BYTES_PER_DEPOSITOR <= _composeMsg.length) {
            // Extract AP address (20 bytes)
            address depositorAddress = _composeMsg.readAddress(offset);
            offset += 20;

            // Get the cached Weiroll Wallet for this depositor for the DUAL_TOKEN bridge nonce
            address cachedWeriollWallet = nonceToDepositorToWeirollWallet[_nonce][depositorAddress];

            // Extract deposit amount (12 bytes)
            uint96 depositAmount = _composeMsg.readUint96(offset);
            // Check that the total amount deposited into Weiroll Wallets isn't more than the amount bridged
            amountDeposited += depositAmount;
            require(amountDeposited <= _tokenAmountBridged, CantDepositMoreThanAmountBridged());
            offset += 12;

            // Transfer the deposited tokens to the Weiroll wallet
            _depositToken.safeTransfer(cachedWeriollWallet, depositAmount);

            // Delete cached Weiroll Wallet after the second constituent has been transferred to the wallet
            delete nonceToDepositorToWeirollWallet[_nonce][depositorAddress];
        }
    }

    /// @dev Deploys a Weiroll wallet for the depositor if not already deployed.
    /// @param _sourceMarketHash The source market's's hash.
    /// @param _owner The owner of the Weiroll wallet (AP address).
    /// @param _amount The amount deposited.
    /// @param _lockedUntil The timestamp until which the wallet is locked.
    /// @return weirollWallet The address of the Weiroll wallet.
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

    /// @dev Internal function to execute the deposit script.
    /// @param _weirollWallet The address of the Weiroll wallet.
    /// @param _sourceMarketHash The source market's hash.
    function _executeDepositRecipe(bytes32 _sourceMarketHash, address _weirollWallet) internal depositRecipeNotExecuted(_weirollWallet) {
        // Get the campaign's deposit recipe
        Recipe storage depositRecipe = sourceMarketHashToSingleTokenDepositCampaign[_sourceMarketHash].depositRecipe;

        // Execute the deposit recipe on the Weiroll wallet
        WeirollWallet(payable(_weirollWallet)).executeWeiroll(depositRecipe.weirollCommands, depositRecipe.weirollState);
    }

    /// @dev Internal function to execute the withdrawal script.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function _executeWithdrawalRecipe(address _weirollWallet) internal {
        // Instantiate the WeirollWallet from the wallet address
        WeirollWallet wallet = WeirollWallet(payable(_weirollWallet));

        // Get the source market's hash associated with the Weiroll wallet
        bytes32 sourceMarketHash = wallet.marketHash();

        // Get the source market's to retrieve the withdrawal recipe
        SingleTokenDepositCampaign storage campaign = sourceMarketHashToSingleTokenDepositCampaign[sourceMarketHash];

        // Execute the withdrawal recipe
        wallet.executeWeiroll(campaign.withdrawalRecipe.weirollCommands, campaign.withdrawalRecipe.weirollState);
    }
}
