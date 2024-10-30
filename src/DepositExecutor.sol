// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ILayerZeroComposer } from "src/interfaces/ILayerZeroComposer.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { ClonesWithImmutableArgs } from "@clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import { IOFT } from "src/interfaces/IOFT.sol";
import { OFTComposeMsgCodec } from "src/libraries/OFTComposeMsgCodec.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title DepositExecutor
/// @notice A singleton contract for receiving and deploying bridged deposits on the destination chain for all deposit campaigns.
/// @notice This contract implements ILayerZeroComposer to act on compose messages sent from the source chain.
contract DepositExecutor is ILayerZeroComposer, Ownable2Step, ReentrancyGuardTransient {
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;

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

    /// @dev Represents a Deposit Campaign on the destination chain.
    /// @custom:field dstInputToken The deposit token for the campaign on the destination chain.
    /// @custom:field unlockTimestamp  The ABSOLUTE timestamp until deposits will be locked for this campaign.
    /// @custom:field depositRecipe The Weiroll recipe executed on deposit (specified by the owner of the campaign).
    /// @custom:field withdrawalRecipe The Weiroll recipe executed on withdrawal (specified by the owner of the campaign).
    struct DepositCampaign {
        ERC20 dstInputToken;
        uint256 unlockTimestamp;
        Recipe depositRecipe;
        Recipe withdrawalRecipe;
    }

    /*//////////////////////////////////////////////////////////////
                            State Variables
    //////////////////////////////////////////////////////////////*/

    /// @notice The address of the Weiroll wallet implementation.
    address public immutable WEIROLL_WALLET_IMPLEMENTATION;

    /// @notice The address of the LayerZero endpoint.
    address public lzEndpoint;

    /// @notice Mapping of an ERC20 token to its corresponding LayerZero Omnichain Application (Stargate Pool, Stargate Hydra, OFT Adapters, etc.)
    mapping(ERC20 => address) public tokenToLzOApp;

    /// @dev Mapping from a market hash on the source chain to its owner's address.
    mapping(bytes32 => address) public sourceMarketHashToOwner;

    /// @dev Mapping from a market hash on the source chain to its DepositCampaign struct.
    mapping(bytes32 => DepositCampaign) public sourceMarketHashToDepositCampaign;

    /*//////////////////////////////////////////////////////////////
                           Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a Weiroll wallet executes a withdrawal.
    /// @param weirollWallet The address of the weiroll wallet that executed the withdrawal recipe.
    event WeirollWalletExecutedWithdrawal(address indexed weirollWallet);

    /// @notice Emitted when a Weiroll wallet executes a deposit.
    /// @param weirollWallet The address of the weiroll wallet that executed the deposit recipe.
    event WeirollWalletExecutedDeposit(address indexed weirollWallet);

    /// @notice Emitted on batch execute of Weiroll Wallet deposits.
    /// @param sourceMarketHash The source market hash of the Weiroll Wallets.
    /// @param weirollWallets The addresses of the weiroll wallets that executed the market's deposit recipe.
    event WeirollWalletsExecutedDeposits(bytes32 indexed sourceMarketHash, address[] weirollWallets);

    /// @notice Emitted when bridged deposits are put in fresh Weiroll Wallets.
    /// @param guid The global unique identifier of the bridge transaction.
    /// @param sourceMarketHash The source market hash of the deposits received.
    /// @param weirollWalletsCreated The addresses of the fresh Weiroll Wallets that were created on destination.
    event FreshWeirollWalletsCreated(bytes32 indexed guid, bytes32 indexed sourceMarketHash, address[] weirollWalletsCreated);

    /// @notice Error emitted when the caller is not the owner of the campaign.
    error OnlyOwnerOfDepositCampaign();

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when setting a lzOApp for a token that doesn't match the OApp's underlying token
    error InvalidLzOAppForToken();

    /// @notice Error emitted when the caller is not the owner of the Weiroll wallet.
    error NotOwner();

    /// @notice Error emitted when trying to interact with a locked wallet.
    error WalletLocked();

    /// @notice Error emitted when trying to execute deposit recipe more than once.
    error DepositRecipeAlreadyExecuted();

    /// @notice Error emitted when the caller of the lzCompose function isn't the LZ endpoint address for destination chain.
    error NotFromLzEndpoint();

    /// @notice Error emitted when the _from in the lzCompose function isn't the correct LayerZero OApp address.
    error NotFromLzOApp();

    /// @notice Error emitted when reading from bytes array is out of bounds.
    error EOF();

    /*//////////////////////////////////////////////////////////////
                              Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the owner of the campaign.
    modifier onlyOwnerOfDepositCampaign(bytes32 _sourceMarketHash) {
        require(msg.sender == sourceMarketHashToOwner[_sourceMarketHash], OnlyOwnerOfDepositCampaign());
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
    /// @param _lzEndpoint The address of the LayerZero endpoint.
    /// @param _depositTokens The tokens that are bridged to the destination chain from the source chain. (dest chain addresses)
    /// @param _lzOApps The corresponding LayerZero OApp instances for each deposit token on the destination chain.
    constructor( 
        address _owner,
        address _weirollWalletImplementation,
        address _lzEndpoint,
        ERC20[] memory _depositTokens,
        address[] memory _lzOApps
    )
        Ownable(_owner)
    {
        require(_depositTokens.length == _lzOApps.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _depositTokens.length; ++i) {
            // Check that the token has a valid corresponding lzOApp
            require(IOFT(_lzOApps[i]).token() == address(_depositTokens[i]), InvalidLzOAppForToken());
            tokenToLzOApp[_depositTokens[i]] = _lzOApps[i];
        }

        WEIROLL_WALLET_IMPLEMENTATION = _weirollWalletImplementation;
        lzEndpoint = _lzEndpoint;
    }

    /*//////////////////////////////////////////////////////////////
                          External Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new campaign with the specified parameters.
    /// @param _sourceMarketHash The unique identifier for the campaign.
    /// @param _owner The address of the campaign owner.
    /// @param _dstInputToken The ERC20 token used as input for the campaign.
    function createDepositCampaign(bytes32 _sourceMarketHash, address _owner, ERC20 _dstInputToken) external onlyOwner {
        sourceMarketHashToOwner[_sourceMarketHash] = _owner;
        sourceMarketHashToDepositCampaign[_sourceMarketHash].dstInputToken = _dstInputToken;
    }

    /// @notice Sets the LayerZero endpoint address for this chain.
    /// @param _newLzEndpoint New LayerZero endpoint for this chain
    function setLzEndpoint(address _newLzEndpoint) external onlyOwner {
        lzEndpoint = _newLzEndpoint;
    }

    /// @notice Sets the LayerZero Omnichain App instance for a given token.
    /// @param _token Token to set the LayerZero Omnichain App for.
    /// @param _lzOApp LayerZero Omnichain Application to use to bridge the specified token.
    function setLzOAppForToken(ERC20 _token, address _lzOApp) external onlyOwner {
        require(IOFT(_lzOApp).token() == address(_token), InvalidLzOAppForToken());
        tokenToLzOApp[_token] = _lzOApp;
    }

    /// @notice Sets a new owner for the specified campaign.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _newOwner The address of the new campaign owner.
    function setDepositCampaignOwner(bytes32 _sourceMarketHash, address _newOwner) external onlyOwnerOfDepositCampaign(_sourceMarketHash) {
        sourceMarketHashToOwner[_sourceMarketHash] = _newOwner;
    }

    /// @notice Sets a new owner for the specified campaign.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign on destination.
    function setDepositCampaignLocktime(bytes32 _sourceMarketHash, uint256 _unlockTimestamp) external onlyOwnerOfDepositCampaign(_sourceMarketHash) {
        sourceMarketHashToDepositCampaign[_sourceMarketHash].unlockTimestamp = _unlockTimestamp;
    }

    /// @notice Sets the deposit recipe for a campaign.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _depositRecipe The deposit recipe for the campaign on the destination chain
    function setDepositRecipe(bytes32 _sourceMarketHash, Recipe calldata _depositRecipe) external onlyOwnerOfDepositCampaign(_sourceMarketHash) {
        sourceMarketHashToDepositCampaign[_sourceMarketHash].depositRecipe = _depositRecipe;
    }

    /// @notice Sets the withdrawal recipe for a campaign.
    /// @param _sourceMarketHash The market hash on the source chain used to identify the corresponding campaign on the destination.
    /// @param _withdrawalRecipe The withdrawal recipe for the campaign on the destination chain
    function setWithdrawalRecipe(bytes32 _sourceMarketHash, Recipe calldata _withdrawalRecipe) external onlyOwnerOfDepositCampaign(_sourceMarketHash) {
        sourceMarketHashToDepositCampaign[_sourceMarketHash].withdrawalRecipe = _withdrawalRecipe;
    }

    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from The address initiating the composition.
     * @param _guid The unique identifier for the corresponding LayerZero src/dst tx.
     * @param _message The composed message payload in bytes.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable nonReentrant {
        // Ensure the caller is the LayerZero endpoint
        require(msg.sender == lzEndpoint, NotFromLzEndpoint());

        // Extract the compose message from the _message
        bytes memory composeMessage = OFTComposeMsgCodec.composeMsg(_message);

        // Make sure at least one AP was bridged (32 bytes for sourceMarketHash + 32 bytes for AP payload)
        require(composeMessage.length >= 64, EOF());

        unchecked {
            // Extract the source market's hash (first 32 bytes)
            bytes32 sourceMarketHash;
            assembly ("memory-safe") {
                sourceMarketHash := mload(add(composeMessage, 32))
            }

            DepositCampaign storage depositCampaign = sourceMarketHashToDepositCampaign[sourceMarketHash];

            // Get the market's input token
            ERC20 campaignInputToken = depositCampaign.dstInputToken;

            // Ensure that the _from address is the expected LayerZero OApp contract for this token
            require(_from == tokenToLzOApp[campaignInputToken], NotFromLzOApp());

            uint256 unlockTimestamp = depositCampaign.unlockTimestamp;

            // Calculate the offset to start reading depositor data
            uint256 offset = 32; // Start at the byte after the sourceMarketHash

            // Num depositors bridged = ((bytes of composeMsg - 32 byte sourceMarketHash) / 32 bytes per depositor)
            uint256 numDepositorsBridged = (composeMessage.length - 32) / 32;
            // Keep track of weiroll wallets created for event emission (to be used in deposit recipe execution phase)
            address[] memory weirollWalletsCreated = new address[](numDepositorsBridged);
            uint256 currIndex = 0;

            // Loop through the compose message and process each depositor
            while (offset + 32 <= composeMessage.length) {
                // Extract AP address (20 bytes)
                address apAddress = _readAddress(composeMessage, offset);
                offset += 20;

                // Extract deposit amount (12 bytes)
                uint96 depositAmount = _readUint96(composeMessage, offset);
                offset += 12;

                // Deploy or retrieve the Weiroll wallet for the depositor
                address weirollWallet = _deployWeirollWallet(sourceMarketHash, apAddress, depositAmount, unlockTimestamp);

                // Transfer the deposited tokens to the Weiroll wallet
                campaignInputToken.safeTransfer(weirollWallet, depositAmount);

                // Push fresh weiroll wallet to wallets created array
                weirollWalletsCreated[currIndex++] = weirollWallet;
            }

            emit FreshWeirollWalletsCreated(_guid, sourceMarketHash, weirollWalletsCreated);
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
        onlyOwnerOfDepositCampaign(_sourceMarketHash)
        nonReentrant
    {
        // Keep track of actual wallets that executed the deposit recipe (based on _sourceMarketHash matching the wallet's market hash)
        // address[] memory walletsExecutedDeposit = new address[](_weirollWallets.length);
        // uint256 executedCount = 0;
        // Executed deposit recipes
        for (uint256 i = 0; i < _weirollWallets.length; ++i) {
            if (WeirollWallet(payable(_weirollWallets[i])).marketHash() == _sourceMarketHash) {
                _executeDepositRecipe(_sourceMarketHash, _weirollWallets[i]);
                // walletsExecutedDeposit[executedCount] = _weirollWallets[i];
                // unchecked {
                //     ++executedCount;
                // }
            }
        }
        // // Resize the array to the actual number of wallets that executed the deposit recipe
        // assembly ("memory-safe") {
        //     mstore(walletsExecutedDeposit, executedCount)
        // }
        // emit WeirollWalletsExecutedDeposits(_sourceMarketHash, walletsExecutedDeposit);
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

    /// @dev Deploys a Weiroll wallet for the depositor if not already deployed.
    /// @param _sourceMarketHash The source market's's hash.
    /// @param _owner The owner of the Weiroll wallet (AP address).
    /// @param _amount The amount deposited.
    /// @param _lockedUntil The timestamp until which the wallet is locked.
    /// @return weirollWallet The address of the Weiroll wallet.
    function _deployWeirollWallet(
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
        Recipe storage depositRecipe = sourceMarketHashToDepositCampaign[_sourceMarketHash].depositRecipe;

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
        DepositCampaign storage campaign = sourceMarketHashToDepositCampaign[sourceMarketHash];

        // Execute the withdrawal recipe
        wallet.executeWeiroll(campaign.withdrawalRecipe.weirollCommands, campaign.withdrawalRecipe.weirollState);
    }

    /// @dev Reads an address from bytes at a specific offset.
    /// @param data The bytes array.
    /// @param offset The offset to start reading from.
    /// @return addr The address read from the bytes array.
    function _readAddress(bytes memory data, uint256 offset) internal pure returns (address addr) {
        assembly ("memory-safe") {
            addr := shr(96, mload(add(add(data, 32), offset)))
        }
    }

    /// @dev Reads a uint96 from bytes at a specific offset.
    /// @param data The bytes array.
    /// @param offset The offset to start reading from.
    /// @return value The uint96 value read from the bytes array.
    function _readUint96(bytes memory data, uint256 offset) internal pure returns (uint96 value) {
        assembly ("memory-safe") {
            value := shr(160, mload(add(add(data, 32), offset)))
        }
    }
}
