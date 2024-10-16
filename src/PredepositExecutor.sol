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

    /// @dev Represents a market with associated input token and recipes.
    /// @custom:field inputToken The deposit token for the market.
    /// @custom:field unlockTimestamp  The ABSOLUTE timestamp until deposits will be locked for this market.
    /// @custom:field depositRecipe The weiroll script executed on deposit (specified by the IP/owner of the market).
    /// @custom:field withdrawalRecipe The weiroll script executed on withdrawal (specified by the IP/owner of the market).
    struct Market {
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
    mapping(ERC20 => address) public tokenToStargate;

    /// @dev Mapping from market hash to owner address.
    mapping(bytes32 => address) public marketHashToOwner;

    /// @dev Mapping from market hash to Market struct.
    mapping(bytes32 => Market) public marketHashToMarket;

    /*//////////////////////////////////////////////////////////////
                           Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a Weiroll wallet executes a withdrawal.
    /// @param weirollWallet The address of the weiroll wallet that executed the withdrawal recipe.
    event WeirollWalletExecutedWithdrawal(address indexed weirollWallet);

    /// @notice Emitted when bridged deposits are put in fresh weiroll wallets and executed.
    event BridgedDepositsExecuted(bytes32 indexed guid, bytes32 indexed marketHash);

    /// @notice Error emitted when the caller is not the owner of the market.
    error OnlyOwnerOfMarket();

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when the caller is not the owner of the Weiroll wallet.
    error NotOwner();

    /// @notice Error emitted when trying to interact with a locked wallet.
    error WalletLocked();

    /// @notice Error emitted when the caller of the lzCompose function isn't the valid endpoint address.
    error NotFromValidEndpoint();

    /// @notice Error emitted when the _from in the lzCompose function isn't the correct Stargate address.
    error NotFromStargate();

    /// @notice Error emitted when reading from bytes array is out of bounds.
    error EOF();

    /*//////////////////////////////////////////////////////////////
                              Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the owner of the market.
    modifier onlyOwnerOfMarket(bytes32 _marketHash) {
        require(msg.sender == marketHashToOwner[_marketHash], OnlyOwnerOfMarket());
        _;
    }

    /// @dev Modifier to check if the Weiroll wallet is unlocked.
    modifier weirollIsUnlocked(address _weirollWallet) {
        require(WeirollWallet(payable(_weirollWallet)).lockedUntil() <= block.timestamp, WalletLocked());
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
    /// @param _stargates The corresponding Stargate instances for each bridgable token.
    constructor(
        address _owner,
        address _weirollWalletImplementation,
        address _lzEndpoint,
        ERC20[] memory _predepositTokens,
        address[] memory _stargates
    )
        Ownable(_owner)
    {
        require(_predepositTokens.length == _stargates.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _predepositTokens.length; ++i) {
            tokenToStargate[_predepositTokens[i]] = _stargates[i];
        }

        WEIROLL_WALLET_IMPLEMENTATION = _weirollWalletImplementation;
        lzEndpoint = _lzEndpoint;
    }

    /*//////////////////////////////////////////////////////////////
                          External Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new market with the specified parameters.
    /// @param _marketHash The unique identifier for the market.
    /// @param _owner The address of the market owner.
    /// @param _inputToken The ERC20 token used as input for the market.
    function createMarket(bytes32 _marketHash, address _owner, ERC20 _inputToken) external onlyOwner {
        marketHashToOwner[_marketHash] = _owner;
        marketHashToMarket[_marketHash].inputToken = _inputToken;
    }

    /// @notice Sets the LayerZero endpoint address for this chain.
    /// @param _newLzEndpoint New LayerZero endpoint for this chain
    function setLzEndpoint(address _newLzEndpoint) external onlyOwner {
        lzEndpoint = _newLzEndpoint;
    }

    /// @notice Sets the Stargate instance for a given token.
    /// @param _token Token to set a Stargate instance for.
    /// @param _stargate Stargate instance to set for the specified token.
    function setStargate(ERC20 _token, address _stargate) external onlyOwner {
        tokenToStargate[_token] = _stargate;
    }

    /// @notice Sets a new owner for the specified market.
    /// @param _marketHash The unique identifier for the market.
    /// @param _newOwner The address of the new market owner.
    function setMarketOwner(bytes32 _marketHash, address _newOwner) external onlyOwnerOfMarket(_marketHash) {
        marketHashToOwner[_marketHash] = _newOwner;
    }

    /// @notice Sets a new owner for the specified market.
    /// @param _marketHash The unique identifier for the market.
    /// @param _unlockTimestamp The ABSOLUTE timestamp until deposits will be locked for this market.
    function setMarketLocktime(bytes32 _marketHash, uint256 _unlockTimestamp) external onlyOwnerOfMarket(_marketHash) {
        marketHashToMarket[_marketHash].unlockTimestamp = _unlockTimestamp;
    }

    /// @notice Sets the deposit recipe for a market.
    /// @param _marketHash The unique identifier for the market.
    /// @param _weirollCommands The weiroll commands for the deposit recipe.
    /// @param _weirollState The weiroll state for the deposit recipe.
    function setDepositRecipe(
        bytes32 _marketHash,
        bytes32[] calldata _weirollCommands,
        bytes[] calldata _weirollState
    )
        external
        onlyOwnerOfMarket(_marketHash)
    {
        marketHashToMarket[_marketHash].depositRecipe = Recipe(_weirollCommands, _weirollState);
    }

    /// @notice Sets the withdrawal recipe for a market.
    /// @param _marketHash The unique identifier for the market.
    /// @param _weirollCommands The weiroll commands for the withdrawal recipe.
    /// @param _weirollState The weiroll state for the withdrawal recipe.
    function setWithdrawalRecipe(
        bytes32 _marketHash,
        bytes32[] calldata _weirollCommands,
        bytes[] calldata _weirollState
    )
        external
        onlyOwnerOfMarket(_marketHash)
    {
        marketHashToMarket[_marketHash].withdrawalRecipe = Recipe(_weirollCommands, _weirollState);
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

        // Make sure at least one AP was bridged (32 bytes for marketHash + 32 bytes for AP payload)
        require(composeMessage.length >= 64, EOF());

        // Extract the market's hash (first 32 bytes)
        bytes32 marketHash;
        assembly ("memory-safe") {
            marketHash := mload(add(composeMessage, 32))
        }

        // Get the market's input token
        ERC20 marketInputToken = marketHashToMarket[marketHash].inputToken;

        // Ensure that the _from address is the expected Stargate contract
        require(_from == tokenToStargate[marketInputToken], NotFromStargate());

        uint256 unlockTimestampForMarket = marketHashToMarket[marketHash].unlockTimestamp;

        // Calculate the offset to start reading depositor data
        uint256 offset = 32; // Start at the byte after the marketHash

        // Loop through the compose message and process each depositor
        while (offset + 32 <= composeMessage.length) {
            // Extract AP address (20 bytes)
            address apAddress = _readAddress(composeMessage, offset);
            offset += 20;

            // Extract deposit amount (12 bytes)
            uint96 depositAmount = _readUint96(composeMessage, offset);
            offset += 12;

            // Deploy or retrieve the Weiroll wallet for the depositor
            address payable weirollWallet = _deployWeirollWallet(marketHash, apAddress, depositAmount, unlockTimestampForMarket);

            // Transfer the deposited tokens to the Weiroll wallet
            marketInputToken.safeTransfer(weirollWallet, depositAmount);

            // Execute the deposit recipe on the Weiroll wallet
            _executeDepositRecipe(weirollWallet, marketHash);
        }

        emit BridgedDepositsExecuted(_guid, marketHash);
    }

    /// @notice Executes the withdrawal script in the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function executeWithdrawalScript(address payable _weirollWallet) external isWeirollOwner(_weirollWallet) weirollIsUnlocked(_weirollWallet) {
        _executeWithdrawalScript(_weirollWallet);
    }

    /*//////////////////////////////////////////////////////////////
                          Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys a Weiroll wallet for the depositor if not already deployed.
    /// @param _marketHash The market's hash.
    /// @param _owner The owner of the Weiroll wallet (AP address).
    /// @param _amount The amount deposited.
    /// @param _lockedUntil The timestamp until which the wallet is locked.
    /// @return weirollWallet The address of the Weiroll wallet.
    function _deployWeirollWallet(
        bytes32 _marketHash,
        address _owner,
        uint256 _amount,
        uint256 _lockedUntil
    )
        internal
        returns (address payable weirollWallet)
    {
        // Deploy a new non-forfeitable Weiroll Wallet with immutable args
        bytes memory weirollParams = abi.encodePacked(_owner, address(this), _amount, _lockedUntil, false, _marketHash);
        weirollWallet = payable(WEIROLL_WALLET_IMPLEMENTATION.clone(weirollParams));
    }

    /// @dev Executes the deposit recipe on the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    /// @param _marketHash The market hash.
    function _executeDepositRecipe(address payable _weirollWallet, bytes32 _marketHash) internal {
        // Get the market's deposit recipe
        Recipe storage depositRecipe = marketHashToMarket[_marketHash].depositRecipe;

        // Execute the deposit recipe on the Weiroll wallet
        WeirollWallet(_weirollWallet).executeWeiroll(depositRecipe.weirollCommands, depositRecipe.weirollState);
    }

    /// @dev Internal function to execute the withdrawal script.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function _executeWithdrawalScript(address payable _weirollWallet) internal {
        // Instantiate the WeirollWallet from the wallet address
        WeirollWallet wallet = WeirollWallet(_weirollWallet);

        // Get the market hash associated with the Weiroll wallet
        bytes32 marketHash = wallet.marketHash();

        // Get the market to retrieve the withdrawal recipe
        Market storage market = marketHashToMarket[marketHash];

        // Execute the withdrawal recipe
        wallet.executeWeiroll(market.withdrawalRecipe.weirollCommands, market.withdrawalRecipe.weirollState);

        emit WeirollWalletExecutedWithdrawal(_weirollWallet);
    }

    /// @dev Reads an address from bytes at a specific offset.
    /// @param data The bytes array.
    /// @param offset The offset to start reading from.
    /// @return addr The address read from the bytes array.
    function _readAddress(bytes memory data, uint256 offset) internal pure returns (address addr) {
        require(data.length >= offset + 20, EOF());
        assembly ("memory-safe") {
            addr := shr(96, mload(add(add(data, 32), offset)))
        }
    }

    /// @dev Reads a uint96 from bytes at a specific offset.
    /// @param data The bytes array.
    /// @param offset The offset to start reading from.
    /// @return value The uint96 value read from the bytes array.
    function _readUint96(bytes memory data, uint256 offset) internal pure returns (uint96 value) {
        require(data.length >= offset + 12, EOF());
        assembly ("memory-safe") {
            value := shr(160, mload(add(add(data, 32), offset)))
        }
    }
}
