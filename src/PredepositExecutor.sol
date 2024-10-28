// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ILayerZeroComposer } from "src/interfaces/ILayerZeroComposer.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { ClonesWithImmutableArgs } from "@clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import { OFTComposeMsgCodec } from "src/libraries/OFTComposeMsgCodec.sol";

/// @title PredepositExecutor
/// @notice A singleton contract for deploying bridged funds to the appropriate protocols on Berachain.
/// @notice This contract implements ILayerZeroComposer to act on compose messages sent from the source chain.
contract PredepositExecutor is ILayerZeroComposer, Ownable2Step {
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                               Structures
    //////////////////////////////////////////////////////////////*/

    /// @dev Represents the recipe containing weiroll commands and state.
    /// @custom:field weirollCommands The weiroll script executed on an AP's weiroll wallet after receiving the inputToken.
    /// @custom:field weirollState State of the weiroll VM, necessary for executing the weiroll script.
    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    /// @dev Represents a campaign with associated input token and recipes.
    /// @custom:field inputToken The deposit token for the campaign.
    /// @custom:field unlockTimestamp  The ABSOLUTE timestamp until deposits will be locked for this campaign.
    /// @custom:field depositRecipe The weiroll script executed on deposit (specified by the IP/owner of the campaign).
    /// @custom:field withdrawalRecipe The weiroll script executed on withdrawal (specified by the IP/owner of the campaign).
    struct PredepositCampaign {
        ERC20 inputToken;
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

    /// @notice Mapping of ERC20 token to its corresponding Stargate bridge entrypoint.
    mapping(ERC20 => address) public tokenToStargatePool;

    /// @dev Mapping from campaign hash to owner address.
    mapping(bytes32 => address) public sourceMarketHashToOwner;

    /// @dev Mapping from campaign hash to PredepositCampaign struct.
    mapping(bytes32 => PredepositCampaign) public sourceMarketHashToPredepositCampaign;

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
    error OnlyOwnerOfPredepositCampaign();

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when the caller is not the owner of the Weiroll wallet.
    error NotOwner();

    /// @notice Error emitted when trying to interact with a locked wallet.
    error WalletLocked();

    /// @notice Error emitted when trying to execute deposit recipe more than once.
    error DepositRecipeAlreadyExecuted();

    /// @notice Error emitted when the caller of the lzCompose function isn't the valid endpoint address.
    error NotFromValidEndpoint();

    /// @notice Error emitted when the _from in the lzCompose function isn't the correct Stargate address.
    error NotFromStargatePool();

    /// @notice Error emitted when reading from bytes array is out of bounds.
    error EOF();

    /*//////////////////////////////////////////////////////////////
                              Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the owner of the campaign.
    modifier onlyOwnerOfPredepositCampaign(bytes32 _sourceMarketHash) {
        require(msg.sender == sourceMarketHashToOwner[_sourceMarketHash], OnlyOwnerOfPredepositCampaign());
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

    /// @notice Constructor to initialize the contract.
    /// @param _owner The address of the owner of this contract.
    /// @param _weirollWalletImplementation The address of the Weiroll wallet implementation.
    /// @param _lzEndpoint The address of the LayerZero endpoint.
    /// @param _predepositTokens The tokens to bridge to Berachain.
    /// @param _stargatePools The corresponding stargate pools instances for each bridgable token.
    constructor(
        address _owner,
        address _weirollWalletImplementation,
        address _lzEndpoint,
        ERC20[] memory _predepositTokens,
        address[] memory _stargatePools
    )
        Ownable(_owner)
    {
        require(_predepositTokens.length == _stargatePools.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _predepositTokens.length; ++i) {
            tokenToStargatePool[_predepositTokens[i]] = _stargatePools[i];
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
    /// @param _inputToken The ERC20 token used as input for the campaign.
    function createPredepositCampaign(bytes32 _sourceMarketHash, address _owner, ERC20 _inputToken) external onlyOwner {
        sourceMarketHashToOwner[_sourceMarketHash] = _owner;
        sourceMarketHashToPredepositCampaign[_sourceMarketHash].inputToken = _inputToken;
    }

    /// @notice Sets the LayerZero endpoint address for this chain.
    /// @param _newLzEndpoint New LayerZero endpoint for this chain
    function setLzEndpoint(address _newLzEndpoint) external onlyOwner {
        lzEndpoint = _newLzEndpoint;
    }

    /// @notice Sets the Stargate instance for a given token.
    /// @param _token Token to set a Stargate pool instance for.
    /// @param _stargatePool Stargate pool instance to set for the specified token.
    function setStargatePool(ERC20 _token, address _stargatePool) external onlyOwner {
        tokenToStargatePool[_token] = _stargatePool;
    }

    /// @notice Sets a new owner for the specified campaign.
    /// @param _sourceMarketHash The unique identifier for the campaign.
    /// @param _newOwner The address of the new campaign owner.
    function setPredepositCampaignOwner(bytes32 _sourceMarketHash, address _newOwner) external onlyOwnerOfPredepositCampaign(_sourceMarketHash) {
        sourceMarketHashToOwner[_sourceMarketHash] = _newOwner;
    }

    /// @notice Sets a new owner for the specified campaign.
    /// @param _sourceMarketHash The unique identifier for the campaign.
    /// @param _unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this campaign.
    function setPredepositCampaignLocktime(bytes32 _sourceMarketHash, uint256 _unlockTimestamp) external onlyOwnerOfPredepositCampaign(_sourceMarketHash) {
        sourceMarketHashToPredepositCampaign[_sourceMarketHash].unlockTimestamp = _unlockTimestamp;
    }

    /// @notice Sets the deposit recipe for a campaign.
    /// @param _sourceMarketHash The unique identifier for the campaign.
    /// @param _depositRecipe The deposit recipe for the source market on the destination chain
    function setDepositRecipe(bytes32 _sourceMarketHash, Recipe calldata _depositRecipe) external onlyOwnerOfPredepositCampaign(_sourceMarketHash) {
        sourceMarketHashToPredepositCampaign[_sourceMarketHash].depositRecipe = _depositRecipe;
    }

    /// @notice Sets the withdrawal recipe for a campaign.
    /// @param _sourceMarketHash The unique identifier for the campaign.
    /// @param _withdrawalRecipe The withdrawal recipe for the source market on the destination chain
    function setWithdrawalRecipe(bytes32 _sourceMarketHash, Recipe calldata _withdrawalRecipe) external onlyOwnerOfPredepositCampaign(_sourceMarketHash) {
        sourceMarketHashToPredepositCampaign[_sourceMarketHash].withdrawalRecipe = _withdrawalRecipe;
    }

    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from The address initiating the composition.
     * @param _guid The unique identifier for the corresponding LayerZero src/dst tx.
     * @param _message The composed message payload in bytes.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata) external payable {
        // Ensure the caller is the LayerZero endpoint
        require(msg.sender == lzEndpoint, NotFromValidEndpoint());

        // Extract the compose message from the _message
        bytes memory composeMessage = OFTComposeMsgCodec.composeMsg(_message);

        // Make sure at least one AP was bridged (32 bytes for sourceMarketHash + 32 bytes for AP payload)
        require(composeMessage.length >= 64, EOF());

        // Extract the source market's hash (first 32 bytes)
        bytes32 sourceMarketHash;
        assembly ("memory-safe") {
            sourceMarketHash := mload(add(composeMessage, 32))
        }

        // Get the market's input token
        ERC20 campaignInputToken = sourceMarketHashToPredepositCampaign[sourceMarketHash].inputToken;

        // Ensure that the _from address is the expected Stargate contract
        require(_from == tokenToStargatePool[campaignInputToken], NotFromStargatePool());

        uint256 unlockTimestampForPredepositCampaign = sourceMarketHashToPredepositCampaign[sourceMarketHash].unlockTimestamp;

        // Calculate the offset to start reading depositor data
        uint256 offset = 32; // Start at the byte after the sourceMarketHash

        // Num depositors bridged = ((bytes of composeMsg - 32 byte sourceMarketHash) / 32 bytes per depositor)
        uint256 numDepositorsBridged = (composeMessage.length - 32) / 32;
        // Keep track of weiroll wallets created for event emission (to be used in deposit recipe execution phase)
        address[] memory weirollWalletsCreated = new address[](numDepositorsBridged);
        uint256 currIndex;

        // Loop through the compose message and process each depositor
        while (offset + 32 <= composeMessage.length) {
            // Extract AP address (20 bytes)
            address apAddress = _readAddress(composeMessage, offset);
            offset += 20;

            // Extract deposit amount (12 bytes)
            uint96 depositAmount = _readUint96(composeMessage, offset);
            offset += 12;

            // Deploy or retrieve the Weiroll wallet for the depositor
            address weirollWallet = _deployWeirollWallet(sourceMarketHash, apAddress, depositAmount, unlockTimestampForPredepositCampaign);

            // Transfer the deposited tokens to the Weiroll wallet
            campaignInputToken.safeTransfer(weirollWallet, depositAmount);

            // Push fresh weiroll wallet to creation array
            weirollWalletsCreated[currIndex++] = weirollWallet;
        }

        emit FreshWeirollWalletsCreated(_guid, sourceMarketHash, weirollWalletsCreated);
    }

    /// @notice Executes the deposit scripts for the specified Weiroll wallets.
    /// @param _sourceMarketHash The source market hash of the Weiroll wallets' market.
    /// @param _weirollWallets The addresses of the Weiroll wallets.
    function executeDepositRecipes(bytes32 _sourceMarketHash, address[] calldata _weirollWallets) external onlyOwnerOfPredepositCampaign(_sourceMarketHash) {
        // Keep track of actual wallets that executed the deposit recipe (based on _sourceMarketHash matching the wallet's market hash)
        address[] memory walletsExecutedDeposit = new address[](_weirollWallets.length);
        uint256 executedCount = 0;
        // Executed deposit recipes
        for (uint256 i = 0; i < _weirollWallets.length; ++i) {
            if (WeirollWallet(payable(_weirollWallets[i])).marketHash() == _sourceMarketHash) {
                _executeDepositRecipe(_sourceMarketHash, _weirollWallets[i]);
                walletsExecutedDeposit[executedCount] = _weirollWallets[i];
                ++executedCount;
            }
        }
        // Resize the array to the actual number of executed wallets
        assembly ("memory-safe") {
            mstore(walletsExecutedDeposit, executedCount)
        }
        emit WeirollWalletsExecutedDeposits(_sourceMarketHash, walletsExecutedDeposit);
    }

    /// @notice Executes the deposit script in the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function executeDepositRecipe(address _weirollWallet) external isWeirollOwner(_weirollWallet) {
        _executeDepositRecipe(WeirollWallet(payable(_weirollWallet)).marketHash(), _weirollWallet);
        emit WeirollWalletExecutedDeposit(_weirollWallet);
    }

    /// @notice Executes the withdrawal script in the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function executeWithdrawalRecipe(address _weirollWallet) external isWeirollOwner(_weirollWallet) weirollIsUnlocked(_weirollWallet) {
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
        Recipe storage depositRecipe = sourceMarketHashToPredepositCampaign[_sourceMarketHash].depositRecipe;

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
        PredepositCampaign storage campaign = sourceMarketHashToPredepositCampaign[sourceMarketHash];

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
