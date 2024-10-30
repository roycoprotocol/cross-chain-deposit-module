// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { RecipeMarketHubBase, ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt } from "src/interfaces/IOFT.sol";
import { OptionsBuilder } from "src/libraries/OptionsBuilder.sol";
import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title DepositLocker
/// @notice A singleton contract for managing deposits for the destination chain on the source chain.
/// @notice Facilitates deposits, withdrawals, and bridging deposits for all deposit markets.
contract DepositLocker is Ownable2Step, ReentrancyGuardTransient {
    using SafeTransferLib for ERC20;
    using OptionsBuilder for bytes;

    // Limit for how many depositers can be bridged in a single transaction
    // At this limit, ~10m gas will be consumed to execute the lzCompose logic on the destination's DepositExecutor
    uint256 public constant MAX_DEPOSITORS_PER_BRIDGE = 100;

    /*//////////////////////////////////////////////////////////////
                                   State
    //////////////////////////////////////////////////////////////*/

    /// @notice The RecipeMarketHub keeping track of all markets and offers.
    RecipeMarketHubBase public immutable RECIPE_MARKET_HUB;

    /// @notice The LayerZero endpoint ID for the destination chain.
    uint32 public dstChainLzEid;

    /// @notice Mapping of an ERC20 token to its corresponding LayerZero Omnichain Application (Stargate Pool, Stargate Hydra, OFT Adapters, etc.)
    mapping(ERC20 => IOFT) public tokenToLzOApp;

    /// @notice Address of the DepositExecutor on the destination chain.
    /// @notice This address will receive all bridged tokens and be responsible for executing all lzCompose logic on the destination chain.
    address public depositExecutor;

    /// @notice Mapping from Royco Market Hash to the multisig address between the market's IP and the destination chain.
    mapping(bytes32 => address) public marketHashToMultisig;

    /// @notice Mapping from market hash to depositor's Weiroll wallet address to amount deposited.
    mapping(bytes32 => mapping(address => uint256)) public marketHashToDepositorToAmountDeposited;

    /// @notice Mapping from market hash to green light status for bridging funds.
    mapping(bytes32 => bool) public marketHashToGreenLight;

    /*//////////////////////////////////////////////////////////////
                                Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits funds.
    event UserDeposited(bytes32 indexed marketHash, address depositorWeirollWallet, uint256 amountDeposited);

    /// @notice Emitted when a user withdraws funds.
    event UserWithdrawn(bytes32 indexed marketHash, address depositorWeirollWallet, uint256 amountWithdrawn);

    /// @notice Emitted when funds are bridged to the destination chain.
    event BridgedToDestinationChain(bytes32 indexed guid, uint64 indexed nonce, bytes32 indexed marketHash, uint256 amountBridged);

    /// @notice Error emitted when setting a lzOApp for a token that doesn't match the OApp's underlying token
    error InvalidLzOAppForToken();

    /// @notice Error emitted when calling withdraw with nothing deposited
    error NothingToWithdraw();

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when green light is not given for bridging.
    error GreenLightNotGiven();

    /// @notice Error emitted when the caller is not the authorized multisig for the market.
    error UnauthorizedMultisigForThisMarket();

    /// @notice Error emitted when attempting to bridge more than the bridge limit
    error ExceededDepositorsPerBridgeLimit();

    /// @notice Error emitted when attempting to bridge 0 depositors.
    error MustBridgeAtLeastOneDepositor();

    /// @notice Error emitted when insufficient msg.value is provided for the bridge fee.
    error InsufficientMsgValueForBridge();

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
                                   Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the DepositLocker Contract.
    /// @param _owner The address of the owner of the contract.
    /// @param _dstChainLzEid The destination LayerZero endpoint ID for the destination chain.
    /// @param _depositExecutor The address of the the DepositExecutor on the destination chain.
    /// @param _recipeMarketHub The address of the recipe market hub used to create markets on the source chain.
    /// @param _depositTokens The tokens to bridge to the destination chain from the source chain. (source chain addresses)
    /// @param _lzOApps The corresponding LayerZero OApp instances for each deposit token on the source chain.
    constructor(
        address _owner,
        uint32 _dstChainLzEid,
        address _depositExecutor,
        RecipeMarketHubBase _recipeMarketHub,
        ERC20[] memory _depositTokens,
        IOFT[] memory _lzOApps
    )
        Ownable(_owner)
    {
        // Check that each token that will be bridged has a corresponding LZOApp instance
        require(_depositTokens.length == _lzOApps.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _depositTokens.length; ++i) {
            // Check that the token has a valid corresponding lzOApp
            require(_lzOApps[i].token() == address(_depositTokens[i]), InvalidLzOAppForToken());
            tokenToLzOApp[_depositTokens[i]] = _lzOApps[i];
        }
        RECIPE_MARKET_HUB = _recipeMarketHub;
        dstChainLzEid = _dstChainLzEid;
        depositExecutor = _depositExecutor;
    }

    /// @notice Called by the deposit script from the depositor's Weiroll wallet.
    function deposit() external nonReentrant {
        // Instantiate Weiroll wallet
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        // Get depositor's Market Hash and amount
        bytes32 targetMarketHash = wallet.marketHash();
        uint256 amountDeposited = wallet.amount();

        // Transfer the deposit amount and update accounting
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);
        marketInputToken.safeTransferFrom(msg.sender, address(this), amountDeposited);
        marketHashToDepositorToAmountDeposited[targetMarketHash][msg.sender] = amountDeposited;

        // Emit deposit event
        emit UserDeposited(targetMarketHash, msg.sender, amountDeposited);
    }

    /// @notice Called by the withdraw script from the depositor's Weiroll wallet.
    function withdraw() external nonReentrant {
        // Instantiate Weiroll wallet
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        // Get depositor's Market Hash and amount
        bytes32 targetMarketHash = wallet.marketHash();

        // Update accounting
        uint256 amountToWithdraw = marketHashToDepositorToAmountDeposited[targetMarketHash][msg.sender];
        require(amountToWithdraw > 0, NothingToWithdraw());
        delete marketHashToDepositorToAmountDeposited[targetMarketHash][msg.sender];

        // Transfer back the amount deposited
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);
        marketInputToken.safeTransfer(msg.sender, amountToWithdraw);

        // Emit withdrawal event
        emit UserWithdrawn(targetMarketHash, msg.sender, amountToWithdraw);
    }

    /// @notice Bridges depositors from the source chain to the destination chain.
    /// @dev Green light must be given before calling.
    /// @param _marketHash The hash of the market to bridge tokens for.
    /// @param _executorGasLimit The gas limit of the executor on the destination chain.
    /// @param _depositorWeirollWallets The addresses of the Weiroll wallets used to deposit.
    function bridge(
        bytes32 _marketHash,
        uint128 _executorGasLimit,
        address payable[] calldata _depositorWeirollWallets
    )
        external
        payable
        greenLightGiven(_marketHash)
        nonReentrant
    {
        require(_depositorWeirollWallets.length <= MAX_DEPOSITORS_PER_BRIDGE, ExceededDepositorsPerBridgeLimit());

        /*
        Payload Structure:
            - marketHash: bytes32 (32 byte)
        Per Depositor:
            - AP / Wallet owner address: address (20 bytes)
            - Amount Deposited: uint96 (12 bytes)
            Total per depositor: 32 bytes
        */

        // Initialize compose message - first 32 bytes is the market hash
        bytes memory composeMsg = abi.encodePacked(_marketHash);

        // Keep track of total amount of deposits to bridge
        uint256 totalAmountToBridge;

        for (uint256 i = 0; i < _depositorWeirollWallets.length; ++i) {
            // Get amount deposited by the Weiroll Wallet
            uint256 depositAmount = marketHashToDepositorToAmountDeposited[_marketHash][_depositorWeirollWallets[i]];
            if (depositAmount == 0 || depositAmount > type(uint96).max) {
                continue; // Skip if didn't deposit or deposit amount is too much to bridge
            }
            // Update the total amount to bridge and clear the depositor's deposit amount
            totalAmountToBridge += depositAmount;
            delete marketHashToDepositorToAmountDeposited[_marketHash][_depositorWeirollWallets[i]];

            // Concatenate depositor's payload (32 bytes) to the lz compose message
            composeMsg = abi.encodePacked(composeMsg, bytes20(uint160(WeirollWallet(_depositorWeirollWallets[i]).owner())), uint96(depositAmount));
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

        // Get the lzOApp for the market's input token
        IOFT lzOApp = tokenToLzOApp[marketInputToken];

        // Get fee quote for bridging
        MessagingFee memory messagingFee = lzOApp.quoteSend(sendParam, false);
        require(msg.value >= messagingFee.nativeFee, InsufficientMsgValueForBridge());

        // Approve the lzOApp to bridge tokens
        marketInputToken.safeApprove(address(lzOApp), totalAmountToBridge);

        // Execute the bridge transaction
        (MessagingReceipt memory messageReceipt, OFTReceipt memory bridgeReceipt) =
            lzOApp.send{ value: messagingFee.nativeFee }(sendParam, messagingFee, address(this));

        // Ensure that all deposits were bridged
        require(totalAmountToBridge == bridgeReceipt.amountReceivedLD, FailedToBridgeAllDeposits());

        // Refund excess value sent with the transaction
        if (msg.value > messagingFee.nativeFee) {
            payable(msg.sender).transfer(msg.value - messagingFee.nativeFee);
        }

        // Emit event to keep track of bridged deposits
        emit BridgedToDestinationChain(messageReceipt.guid, messageReceipt.nonce, _marketHash, totalAmountToBridge);
    }

    /// @notice Sets the LayerZero endpoint ID for the destination chain.
    /// @param _dstChainLzEid LayerZero endpoint ID for the destination chain.
    function setDestinationChainEid(uint32 _dstChainLzEid) external onlyOwner {
        dstChainLzEid = _dstChainLzEid;
    }

    /// @notice Sets the LayerZero Omnichain App instance for a given token.
    /// @param _token Token to set the LayerZero Omnichain App for.
    /// @param _lzOApp LayerZero Omnichain Application to use to bridge the specified token.
    function setLzOAppForToken(ERC20 _token, IOFT _lzOApp) external onlyOwner {
        require(_lzOApp.token() == address(_token), InvalidLzOAppForToken());
        tokenToLzOApp[_token] = _lzOApp;
    }

    /// @notice Sets the DepositExecutor address.
    /// @param _depositExecutor Address of the new DepositExecutor on the destination chain.
    function setDepositExecutor(address _depositExecutor) external onlyOwner {
        depositExecutor = _depositExecutor;
    }

    /// @notice Sets the multisig address for a market.
    /// @param _marketHash The market hash to set the multisig for.
    /// @param _multisig The address of the multisig contract between the market's IP and the destination chain.
    function setMulitsig(bytes32 _marketHash, address _multisig) external onlyOwner {
        marketHashToMultisig[_marketHash] = _multisig;
    }

    /// @notice Sets the green light status for a market.
    /// @param _marketHash The market hash to set the green light for.
    /// @param _greenLightStatus Boolean indicating if funds are ready to bridge.
    function setGreenLight(bytes32 _marketHash, bool _greenLightStatus) external onlyMultisig(_marketHash) {
        marketHashToGreenLight[_marketHash] = _greenLightStatus;
    }

    /// @dev Converts an address to bytes32.
    /// @param _addr The address to convert.
    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
