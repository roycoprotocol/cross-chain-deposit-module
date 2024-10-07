// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IWeirollWallet} from "src/interfaces/IWeirollWallet.sol";
import {ILayerZeroComposer} from "src/interfaces/ILayerZeroComposer.sol";
import {ClonesWithImmutableArgs} from "lib/clones-with-immutable-args/src/ClonesWithImmutableArgs.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

/// @title BerachainPredepositDeployer
/// @author ShivaanshK, corddry
/// @notice A singleton contract for deploying bridged funds to the appropriate protocols on Berachain.
/// @notice This contract implements ILayerZeroComposer to act on compose messages sent from the source chain.
contract BerachainPredepositDeployer is ILayerZeroComposer, Ownable2Step {
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;

    /// @dev Represents the recipe containing weiroll commands and state.
    /// @custom:field weirollCommands The weiroll script executed on an AP's weiroll wallet after receiving the inputToken.
    /// @custom:field weirollState State of the weiroll VM, necessary for executing the weiroll script.
    struct Recipe {
        bytes32[] weirollCommands;
        bytes[] weirollState;
    }

    /// @dev Represents a market with associated input token and recipes.
    struct Market {
        ERC20 inputToken;
        Recipe depositRecipe;
        Recipe withdrawalRecipe;
    }

    /// @notice The address of the Weiroll wallet implementation.
    address public immutable WEIROLL_WALLET_IMPLEMENTATION;

    /// @dev Mapping from market ID to owner address.
    mapping(uint256 => address) internal marketIdToOwner;

    /// @dev Mapping from market ID to Market struct.
    mapping(uint256 => Market) internal marketIdToMarket;

    /// @notice Emitted when a Weiroll wallet executes a withdrawal.
    /// @param weirollWallet The address of the weiroll wallet that executed the withdrawal recipe.
    event WeirollWalletExecutedWithdrawal(address indexed weirollWallet);

    /// @notice Error emitted when the caller is not the owner of the market.
    error OnlyOwnerOfMarket();

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when the caller is not the owner of the Weiroll wallet.
    error NotOwner();

    /// @notice Error emitted when trying to interact with a locked wallet.
    error WalletLocked();

    /// @dev Modifier to ensure the caller is the owner of the market.
    modifier onlyOwnerOfMarket(uint256 marketId) {
        if (msg.sender != marketIdToOwner[marketId]) {
            revert OnlyOwnerOfMarket();
        }
        _;
    }

    /// @dev Modifier to check if the Weiroll wallet is unlocked.
    modifier weirollIsUnlocked(address weirollWallet) {
        if (IWeirollWallet(payable(weirollWallet)).lockedUntil() > block.timestamp) {
            revert WalletLocked();
        }
        _;
    }

    /// @dev Modifier to ensure the caller is the owner of the Weiroll wallet.
    modifier isWeirollOwner(address weirollWallet) {
        if (IWeirollWallet(payable(weirollWallet)).owner() != msg.sender) {
            revert NotOwner();
        }
        _;
    }

    /// @notice Constructor to initialize the contract.
    /// @param _owner The address of the owner of this contract.
    /// @param _weirollWalletImplementation The address of the Weiroll wallet implementation.
    constructor(address _owner, address _weirollWalletImplementation) Ownable(_owner) {
        WEIROLL_WALLET_IMPLEMENTATION = _weirollWalletImplementation;
    }

    /// @notice Creates a new market with the specified parameters.
    /// @param marketId The unique identifier for the market.
    /// @param owner The address of the market owner.
    /// @param inputToken The ERC20 token used as input for the market.
    function createMarket(uint256 marketId, address owner, ERC20 inputToken) external onlyOwner {
        marketIdToOwner[marketId] = owner;
        marketIdToMarket[marketId].inputToken = inputToken;
    }

    /// @notice Sets a new owner for the specified market.
    /// @param marketId The unique identifier for the market.
    /// @param newOwner The address of the new market owner.
    function setMarketOwner(uint256 marketId, address newOwner) external onlyOwnerOfMarket(marketId) {
        marketIdToOwner[marketId] = newOwner;
    }

    /// @notice Sets the deposit recipe for a market.
    /// @param marketId The unique identifier for the market.
    /// @param weirollCommands The weiroll commands for the deposit recipe.
    /// @param weirollState The weiroll state for the deposit recipe.
    function setDepositRecipe(uint256 marketId, bytes32[] calldata weirollCommands, bytes[] calldata weirollState)
        external
        onlyOwnerOfMarket(marketId)
    {
        marketIdToMarket[marketId].depositRecipe = Recipe(weirollCommands, weirollState);
    }

    /// @notice Sets the withdrawal recipe for a market.
    /// @param marketId The unique identifier for the market.
    /// @param weirollCommands The weiroll commands for the withdrawal recipe.
    /// @param weirollState The weiroll state for the withdrawal recipe.
    function setWithdrawalRecipe(uint256 marketId, bytes32[] calldata weirollCommands, bytes[] calldata weirollState)
        external
        onlyOwnerOfMarket(marketId)
    {
        marketIdToMarket[marketId].withdrawalRecipe = Recipe(weirollCommands, weirollState);
    }

    /**
     * @notice Composes a LayerZero message from an OApp.
     * @param _from The address initiating the composition.
     * @param _guid The unique identifier for the corresponding LayerZero src/dst tx.
     * @param _message The composed message payload in bytes.
     * @param _executor The address of the executor for the composed message.
     * @param _extraData Additional arbitrary data in bytes.
     */
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable {
        // Function implementation can be added here
    }

    /// @notice Executes the withdrawal script in the Weiroll wallet.
    /// @param weirollWallet The address of the Weiroll wallet.
    function executeWithdrawalScript(address weirollWallet)
        external
        isWeirollOwner(weirollWallet)
        weirollIsUnlocked(weirollWallet)
    {
        _executeWithdrawalScript(weirollWallet);
    }

    /// @dev Internal function to execute the withdrawal script.
    /// @param weirollWallet The address of the Weiroll wallet.
    function _executeWithdrawalScript(address weirollWallet) internal {
        // Instantiate the WeirollWallet from the wallet address
        IWeirollWallet wallet = IWeirollWallet(payable(weirollWallet));

        // Get the marketID associated with the Weiroll wallet
        uint256 marketId = wallet.marketId();

        // Get the market to retrieve the withdrawal recipe
        Market storage market = marketIdToMarket[marketId];

        // Execute the withdrawal recipe
        wallet.executeWeiroll(market.withdrawalRecipe.weirollCommands, market.withdrawalRecipe.weirollState);

        emit WeirollWalletExecutedWithdrawal(weirollWallet);
    }
}
