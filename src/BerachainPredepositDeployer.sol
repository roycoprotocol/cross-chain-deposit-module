// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IStargate} from "src/interfaces/IStargate.sol";
import {ILayerZeroComposer} from "src/interfaces/ILayerZeroComposer.sol";
import {IWeirollWallet} from "src/interfaces/IWeirollWallet.sol";
import {ClonesWithImmutableArgs} from "lib/clones-with-immutable-args/src/ClonesWithImmutableArgs.sol";
import {OFTComposeMsgCodec} from "src/libraries/OFTComposeMsgCodec.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

/// @title BerachainPredepositDeployer
/// @notice A singleton contract for deploying bridged funds to the appropriate protocols on Berachain.
/// @notice This contract implements ILayerZeroComposer to act on compose messages sent from the source chain.
contract BerachainPredepositDeployer is ILayerZeroComposer, Ownable2Step {
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
    /// @custom:field depositRecipe The weiroll script executed on deposit (specified by the IP/owner of the market).
    /// @custom:field withdrawalRecipe The weiroll script executed on withdrawal (specified by the IP/owner of the market).
    struct Market {
        ERC20 inputToken;
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
    mapping(ERC20 => IStargate) public tokenToStargate;

    /// @dev Mapping from market ID to owner address.
    mapping(uint256 => address) internal marketIdToOwner;

    /// @dev Mapping from market ID to Market struct.
    mapping(uint256 => Market) internal marketIdToMarket;

    /*//////////////////////////////////////////////////////////////
                           Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a Weiroll wallet executes a withdrawal.
    /// @param weirollWallet The address of the weiroll wallet that executed the withdrawal recipe.
    event WeirollWalletExecutedWithdrawal(address indexed weirollWallet);

    /// @notice Emitted when funds are bridged deposites are deployed.
    event BridgedDepositsDeployed(bytes32 indexed guid, uint256 indexed marketId);

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
    modifier onlyOwnerOfMarket(uint256 _marketId) {
        if (msg.sender != marketIdToOwner[_marketId]) {
            revert OnlyOwnerOfMarket();
        }
        _;
    }

    /// @dev Modifier to check if the Weiroll wallet is unlocked.
    modifier weirollIsUnlocked(address _weirollWallet) {
        if (IWeirollWallet(payable(_weirollWallet)).lockedUntil() > block.timestamp) {
            revert WalletLocked();
        }
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the Weiroll wallet.
    modifier isWeirollOwner(address _weirollWallet) {
        if (IWeirollWallet(payable(_weirollWallet)).owner() != msg.sender) {
            revert NotOwner();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             Constructor
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor to initialize the contract.
    /// @param _owner The address of the owner of this contract.
    /// @param _weirollWalletImplementation The address of the Weiroll wallet implementation.
    /// @param _lzEndpoint The address of the LayerZero endpoint.
    constructor(address _owner, address _weirollWalletImplementation, address _lzEndpoint) Ownable(_owner) {
        WEIROLL_WALLET_IMPLEMENTATION = _weirollWalletImplementation;
        lzEndpoint = _lzEndpoint;
    }

    /*//////////////////////////////////////////////////////////////
                          External Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a new market with the specified parameters.
    /// @param _marketId The unique identifier for the market.
    /// @param _owner The address of the market owner.
    /// @param _inputToken The ERC20 token used as input for the market.
    function createMarket(uint256 _marketId, address _owner, ERC20 _inputToken) external onlyOwner {
        marketIdToOwner[_marketId] = _owner;
        marketIdToMarket[_marketId].inputToken = _inputToken;
    }

    /// @notice Sets a new owner for the specified market.
    /// @param _marketId The unique identifier for the market.
    /// @param _newOwner The address of the new market owner.
    function setMarketOwner(uint256 _marketId, address _newOwner) external onlyOwnerOfMarket(_marketId) {
        marketIdToOwner[_marketId] = _newOwner;
    }

    /// @notice Sets the deposit recipe for a market.
    /// @param _marketId The unique identifier for the market.
    /// @param _weirollCommands The weiroll commands for the deposit recipe.
    /// @param _weirollState The weiroll state for the deposit recipe.
    function setDepositRecipe(uint256 _marketId, bytes32[] calldata _weirollCommands, bytes[] calldata _weirollState)
        external
        onlyOwnerOfMarket(_marketId)
    {
        marketIdToMarket[_marketId].depositRecipe = Recipe(_weirollCommands, _weirollState);
    }

    /// @notice Sets the withdrawal recipe for a market.
    /// @param _marketId The unique identifier for the market.
    /// @param _weirollCommands The weiroll commands for the withdrawal recipe.
    /// @param _weirollState The weiroll state for the withdrawal recipe.
    function setWithdrawalRecipe(uint256 _marketId, bytes32[] calldata _weirollCommands, bytes[] calldata _weirollState)
        external
        onlyOwnerOfMarket(_marketId)
    {
        marketIdToMarket[_marketId].withdrawalRecipe = Recipe(_weirollCommands, _weirollState);
    }

    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from The address initiating the composition.
     * @param _guid The unique identifier for the corresponding LayerZero src/dst tx.
     * @param _message The composed message payload in bytes.
     */
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        external
        payable
    {
        // Ensure the caller is the LayerZero endpoint
        require(msg.sender == lzEndpoint, NotFromValidEndpoint());

        // Extract the compose message from the _message
        bytes memory composeMessage = OFTComposeMsgCodec.composeMsg(_message);

        // Extract market ID (first byte)
        uint256 marketId = uint256(uint8(composeMessage[0]));

        // Get the market's input token
        ERC20 marketInputToken = marketIdToMarket[marketId].inputToken;

        // Get the Stargate address for the input token
        IStargate stargate = tokenToStargate[marketInputToken];

        // Ensure that the _from address is the expected Stargate contract
        require(_from == address(stargate), NotFromStargate());

        // Calculate the offset to start reading depositor data
        uint256 offset = 1; // After the marketId byte

        // Loop through the compose message and process each depositor
        while (offset + 36 <= composeMessage.length) {
            // Extract AP address (20 bytes)
            address apAddress = _readAddress(composeMessage, offset);
            offset += 20;

            // Extract deposit amount (12 bytes)
            uint96 depositAmount = _readUint96(composeMessage, offset);
            offset += 12;

            // Extract wallet lock time (4 bytes)
            uint32 walletLockTime = _readUint32(composeMessage, offset);
            offset += 4;

            // Deploy or retrieve the Weiroll wallet for the depositor
            address weirollWallet = _deployWeirollWallet(marketId, apAddress, depositAmount, walletLockTime);

            // Transfer the deposited tokens to the Weiroll wallet
            marketInputToken.safeTransfer(weirollWallet, depositAmount);

            // Execute the deposit recipe on the Weiroll wallet
            _executeDepositRecipe(weirollWallet, marketId);
        }

        emit BridgedDepositsDeployed(_guid, marketId);
    }

    /// @notice Emergency deployment of deposits in case of issues.
    /// @param _marketId The market ID.
    function emergencyDeploymentOfDeposits(uint256 _marketId) external payable onlyOwnerOfMarket(_marketId) {
        // Implementation of emergency deployment logic
    }

    /// @notice Executes the withdrawal script in the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function executeWithdrawalScript(address _weirollWallet)
        external
        isWeirollOwner(_weirollWallet)
        weirollIsUnlocked(_weirollWallet)
    {
        _executeWithdrawalScript(_weirollWallet);
    }

    /*//////////////////////////////////////////////////////////////
                          Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploys a Weiroll wallet for the depositor if not already deployed.
    /// @param _marketId The market ID.
    /// @param _owner The owner of the Weiroll wallet (AP address).
    /// @param _amount The amount deposited.
    /// @param _lockedUntil The timestamp until which the wallet is locked.
    /// @return weirollWallet The address of the Weiroll wallet.
    function _deployWeirollWallet(uint256 _marketId, address _owner, uint256 _amount, uint256 _lockedUntil)
        internal
        returns (address weirollWallet)
    {
        // Deploy a new Weiroll wallet with immutable args
        bytes memory data = abi.encodePacked(_owner, address(this), _amount, _lockedUntil, false, _marketId);
        weirollWallet = WEIROLL_WALLET_IMPLEMENTATION.clone(data);
    }

    /// @dev Executes the deposit recipe on the Weiroll wallet.
    /// @param _weirollWallet The address of the Weiroll wallet.
    /// @param _marketId The market ID.
    function _executeDepositRecipe(address _weirollWallet, uint256 _marketId) internal {
        // Get the market's deposit recipe
        Recipe storage depositRecipe = marketIdToMarket[_marketId].depositRecipe;

        // Execute the deposit recipe on the Weiroll wallet
        IWeirollWallet(_weirollWallet).executeWeiroll(depositRecipe.weirollCommands, depositRecipe.weirollState);
    }

    /// @dev Internal function to execute the withdrawal script.
    /// @param _weirollWallet The address of the Weiroll wallet.
    function _executeWithdrawalScript(address _weirollWallet) internal {
        // Instantiate the WeirollWallet from the wallet address
        IWeirollWallet wallet = IWeirollWallet(payable(_weirollWallet));

        // Get the market ID associated with the Weiroll wallet
        uint256 marketId = wallet.marketId();

        // Get the market to retrieve the withdrawal recipe
        Market storage market = marketIdToMarket[marketId];

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
        assembly {
            addr := shr(96, mload(add(add(data, 32), offset)))
        }
    }

    /// @dev Reads a uint96 from bytes at a specific offset.
    /// @param data The bytes array.
    /// @param offset The offset to start reading from.
    /// @return value The uint96 value read from the bytes array.
    function _readUint96(bytes memory data, uint256 offset) internal pure returns (uint96 value) {
        require(data.length >= offset + 12, EOF());
        assembly {
            value := shr(160, mload(add(add(data, 32), offset)))
        }
    }

    /// @dev Reads a uint32 from bytes at a specific offset.
    /// @param data The bytes array.
    /// @param offset The offset to start reading from.
    /// @return value The uint32 value read from the bytes array.
    function _readUint32(bytes memory data, uint256 offset) internal pure returns (uint32 value) {
        require(data.length >= offset + 4, EOF());
        assembly {
            value := shr(224, mload(add(add(data, 32), offset)))
        }
    }
}
