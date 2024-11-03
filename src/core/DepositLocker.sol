// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { RecipeMarketHubBase, ERC20, SafeTransferLib, FixedPointMathLib } from "@royco/src/RecipeMarketHub.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt } from "src/interfaces/IOFT.sol";
import { OptionsBuilder } from "src/libraries/OptionsBuilder.sol";
import { DualToken } from "src/periphery/DualToken.sol";
import { DepositType, DepositPayloadLib } from "src/libraries/DepositPayloadLib.sol";

/// @title DepositLocker
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A singleton contract for managing deposits for the destination chain on the source chain.
/// @notice Facilitates deposits, withdrawals, and bridging deposits for all deposit markets.
contract DepositLocker is Ownable2Step, ReentrancyGuardTransient {
    using SafeTransferLib for ERC20;
    using OptionsBuilder for bytes;
    using DepositPayloadLib for bytes;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                               Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice The limit for how many depositers can be bridged in a single transaction
    uint256 public constant MAX_DEPOSITORS_PER_BRIDGE = 100;

    /// @notice The RecipeMarketHub keeping track of all Royco markets and offers.
    RecipeMarketHubBase public immutable RECIPE_MARKET_HUB;

    /*//////////////////////////////////////////////////////////////
                                State
    //////////////////////////////////////////////////////////////*/

    /// @notice The LayerZero endpoint ID for the destination chain.
    uint32 public dstChainLzEid;

    /// @notice Mapping of an ERC20 token to its corresponding LayerZero V2 OFT (OFTs, OFT Adapters, Stargate V2 Pools, Stargate Hydras, etc.)
    mapping(ERC20 => IOFT) public tokenToLzV2OFT;

    /// @notice Address of the DepositExecutor on the destination chain.
    /// @notice This address will receive all bridged tokens and be responsible for executing all lzCompose logic on the destination chain.
    address public depositExecutor;

    /// @notice Mapping from Royco Market Hash to the multisig address between the market's IP and the destination chain.
    mapping(bytes32 => address) public marketHashToMultisig;

    /// @notice Mapping from market hash to depositor's (AP) address to the total amount they deposited. (could span multiple Weiroll Wallets)
    mapping(bytes32 => mapping(address => uint256)) public marketHashToDepositorToAmountDeposited;

    /// @notice Mapping Depositor (AP) to Weiroll Wallets they have deposited with
    mapping(bytes32 => mapping(address => address[])) public marketHashToDepositorToWeirollWallets;

    /// @notice Mapping Depositor (AP) to Weiroll Wallet to amount deposited by that Weiroll Wallet
    mapping(address => mapping(address => uint256)) public depositorToWeirollWalletToAmount;

    /// @notice Mapping from market hash to green light status for bridging funds.
    mapping(bytes32 => bool) public marketHashToGreenLight;

    /// @notice Used to keep track of DUAL_TOKEN bridges
    /// @notice A DUAL_TOKEN bridge will result in 2 OFT bridges (each with the same nonce)
    uint256 public nonce;

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
    /// @param _lzV2OFTs The corresponding LayerZero OApp instances for each deposit token on the source chain.
    constructor(
        address _owner,
        uint32 _dstChainLzEid,
        address _depositExecutor,
        RecipeMarketHubBase _recipeMarketHub,
        ERC20[] memory _depositTokens,
        IOFT[] memory _lzV2OFTs
    )
        Ownable(_owner)
    {
        // Check that each token that will be bridged has a corresponding LZOApp instance
        require(_depositTokens.length == _lzV2OFTs.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _depositTokens.length; ++i) {
            // Check that the token has a valid corresponding lzV2OFT
            require(_lzV2OFTs[i].token() == address(_depositTokens[i]), InvalidLzV2OFTForToken());
            tokenToLzV2OFT[_depositTokens[i]] = _lzV2OFTs[i];
        }
        RECIPE_MARKET_HUB = _recipeMarketHub;
        dstChainLzEid = _dstChainLzEid;
        depositExecutor = _depositExecutor;
    }

    /// @notice Called by the deposit script from the depositor's Weiroll wallet.
    function deposit() external nonReentrant {
        // Get Weiroll Wallet's market hash, depositor/owner/AP, and amount deposited
        WeirollWallet wallet = WeirollWallet(payable(msg.sender));
        bytes32 targetMarketHash = wallet.marketHash();
        address depositor = wallet.owner();
        uint256 amountDeposited = wallet.amount();

        // Transfer the deposit amount from the Weiroll Wallet to the DepositLocker
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(targetMarketHash);
        marketInputToken.safeTransferFrom(msg.sender, address(this), amountDeposited);
        // Account for deposit
        marketHashToDepositorToAmountDeposited[targetMarketHash][depositor] += amountDeposited;
        marketHashToDepositorToWeirollWallets[targetMarketHash][depositor].push(msg.sender);
        depositorToWeirollWalletToAmount[depositor][msg.sender] = amountDeposited;

        // Emit deposit event
        emit UserDeposited(targetMarketHash, depositor, amountDeposited);
    }

    /// @notice Called by the withdraw script from the depositor's Weiroll wallet.
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

    /// @notice Bridges depositors in single token markets from the source chain to the destination chain.
    /// @dev Green light must be given before calling.
    /// @param _marketHash The hash of the market to bridge tokens for.
    /// @param _executorGasLimit The gas limit of the executor on the destination chain.
    /// @param _depositors The addresses of the depositors (APs) to bridge
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
        require(_depositors.length <= MAX_DEPOSITORS_PER_BRIDGE, ExceededDepositorsPerBridgeLimit());

        /*
        Payload Structure:
            Per Payload (33 bytes):
                - DepositType: uint8 (1 byte) - SINGLE_TOKEN
                - marketHash: bytes32 (32 bytes)
            Per Depositor (32 bytes):
                - AP / Wallet owner address: address (20 bytes)
                - Amount Deposited: uint96 (12 bytes)
        */

        // Initialize compose message - first 33 bytes are BRIDGE_TYPE and market hash
        bytes memory composeMsg = DepositPayloadLib.initSingleTokenComposeMsg(_marketHash);

        // Keep track of total amount of deposits to bridge
        uint256 totalAmountToBridge;

        for (uint256 i = 0; i < _depositors.length; ++i) {
            // Get the deposit amount for this depositor
            uint256 depositAmount;

            // Process depositor and update compose message
            (depositAmount, composeMsg) = _processSingleTokenDepositor(_marketHash, _depositors[i], composeMsg);

            // Update the total amount to bridge
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

    /// @notice Bridges depositors in dual token markets from the source chain to the destination chain.
    /// @dev Green light must be given before calling.
    /// @param _marketHash The hash of the market to bridge tokens for.
    /// @param _executorGasLimit The gas limit of the executor on the destination chain.
    /// @param _depositors The addresses of the depositors (APs) to bridge
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
        require(_depositors.length <= MAX_DEPOSITORS_PER_BRIDGE, ExceededDepositorsPerBridgeLimit());

        /*
        Payload Structure:
            Per Payload (33 bytes):
                - DepositType: uint8 (1 byte) - DUAL_TOKEN
                - marketHash: bytes32 (32 bytes)
                - nonce: uint256 (32 bytes)
            Per Depositor (32 bytes):
                - AP / Wallet owner address: address (20 bytes)
                - Amount Deposited: uint96 (12 bytes)
        */

        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        // Extract DualToken constituent tokens and amounts
        DualToken dualToken = DualToken(address(marketInputToken));
        uint256 amountOfTokenAPerDT = dualToken.amountOfTokenAPerDT();
        uint256 amountOfTokenBPerDT = dualToken.amountOfTokenBPerDT();

        // Initialize compose messages for both tokens - first 65 bytes are BRIDGE_TYPE, market hash, and nonce
        bytes memory tokenA_ComposeMsg = DepositPayloadLib.initDualTokenComposeMsg(_marketHash, nonce);
        bytes memory tokenB_ComposeMsg = DepositPayloadLib.initDualTokenComposeMsg(_marketHash, nonce);

        // Keep track of total amount of deposits to bridge
        uint256 dt_totalAmountToBridge;
        uint256 tokenA_TotalAmountToBridge;
        uint256 tokenB_TotalAmountToBridge;

        for (uint256 i = 0; i < _depositors.length; ++i) {
            // Get the deposit amounts for the dual token and each constituent for this depositor
            uint256 dt_depositAmount;
            uint256 tokenA_DepositAmount;
            uint256 tokenB_DepositAmount;

            // Process the depositor and update the compose messages
            (dt_depositAmount, tokenA_DepositAmount, tokenB_DepositAmount, tokenA_ComposeMsg, tokenB_ComposeMsg) =
                _processDualTokenDepositor(_marketHash, _depositors[i], amountOfTokenAPerDT, amountOfTokenBPerDT, tokenA_ComposeMsg, tokenB_ComposeMsg);

            // Update total amounts
            dt_totalAmountToBridge += dt_depositAmount;
            tokenA_TotalAmountToBridge += tokenA_DepositAmount;
            tokenB_TotalAmountToBridge += tokenB_DepositAmount;
        }

        // Ensure that at least one depositor was included in the bridge payload
        require(tokenA_TotalAmountToBridge > 0 && tokenB_TotalAmountToBridge > 0, MustBridgeAtLeastOneDepositor());

        // Burn the dual tokens to receive the constituents in the DepositLocker
        dualToken.burn(dt_totalAmountToBridge);

        // Prepare SendParam for bridging Token A
        SendParam memory sendParam = SendParam({
            dstEid: dstChainLzEid,
            to: _addressToBytes32(depositExecutor),
            amountLD: tokenA_TotalAmountToBridge,
            minAmountLD: tokenA_TotalAmountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _executorGasLimit, 0),
            composeMsg: tokenA_ComposeMsg,
            oftCmd: ""
        });

        // Bridge the tokens with the marshaled send parameters
        MessagingReceipt memory tokenA_MessageReceipt = _bridgeTokens(dualToken.tokenA(), 0, sendParam);
        uint256 totalBridgingFee = tokenA_MessageReceipt.fee.nativeFee;

        // Modify sendParam to bridge Token B
        sendParam.amountLD = tokenB_TotalAmountToBridge;
        sendParam.minAmountLD = tokenB_TotalAmountToBridge;
        sendParam.composeMsg = tokenB_ComposeMsg;

        // Bridge the tokens with the marshaled send parameters
        MessagingReceipt memory tokenB_MessageReceipt = _bridgeTokens(dualToken.tokenB(), totalBridgingFee, sendParam);
        totalBridgingFee += tokenB_MessageReceipt.fee.nativeFee;

        // Refund excess value sent with the transaction
        if (msg.value > totalBridgingFee) {
            payable(msg.sender).transfer(msg.value - totalBridgingFee);
        }

        // Emit event to keep track of bridged deposits
        // Increment the nonce after emission
        emit DualTokenBridgeToDestinationChain(
            _marketHash,
            nonce++,
            tokenA_MessageReceipt.guid,
            tokenA_MessageReceipt.nonce,
            tokenA_TotalAmountToBridge,
            tokenB_MessageReceipt.guid,
            tokenB_MessageReceipt.nonce,
            tokenB_TotalAmountToBridge
        );
    }

    /// @notice Sets the LayerZero endpoint ID for the destination chain.
    /// @param _dstChainLzEid LayerZero endpoint ID for the destination chain.
    function setDestinationChainEid(uint32 _dstChainLzEid) external onlyOwner {
        dstChainLzEid = _dstChainLzEid;
    }

    /// @notice Sets the LayerZero Omnichain App instance for a given token.
    /// @param _token Token to set the LayerZero Omnichain App for.
    /// @param _lzV2OFT LayerZero OFT to use to bridge the specified token.
    function setLzV2OFTForToken(ERC20 _token, IOFT _lzV2OFT) external onlyOwner {
        require(_lzV2OFT.token() == address(_token), InvalidLzV2OFTForToken());
        tokenToLzV2OFT[_token] = _lzV2OFT;
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

    /// @notice Bridges LayerZero V2 OFT tokens
    /// @param _token The token to bridge
    /// @param _feesAlreadyPaid The amount of fees already paid in this transaction prior to this bridge
    /// @param _sendParam The send parameter passed to the quoteSend and send OFT functions
    function _bridgeTokens(ERC20 _token, uint256 _feesAlreadyPaid, SendParam memory _sendParam) internal returns (MessagingReceipt memory messageReceipt) {
        // The amount of the token to bridge in local decimals
        uint256 amountToBridge = _sendParam.amountLD;

        // Get the lzV2OFT for the market's input token
        IOFT lzV2OFT = tokenToLzV2OFT[_token];

        // Get fee quote for bridging
        MessagingFee memory messagingFee = lzV2OFT.quoteSend(_sendParam, false);
        require(msg.value - _feesAlreadyPaid >= messagingFee.nativeFee, InsufficientMsgValueForBridge());

        // Approve the lzV2OFT to bridge tokens
        _token.safeApprove(address(lzV2OFT), amountToBridge);

        // Execute the bridge transaction
        OFTReceipt memory bridgeReceipt;
        (messageReceipt, bridgeReceipt) = lzV2OFT.send{ value: messagingFee.nativeFee }(_sendParam, messagingFee, address(this));

        // Ensure that all deposits were bridged
        require(amountToBridge == bridgeReceipt.amountReceivedLD, FailedToBridgeAllDeposits());
    }

    /**
     * @notice Processes a single token depositor by updating the compose message and clearing depositor data.
     * @dev Updates the compose message with the depositor's information if the deposit amount is valid.
     * @param _marketHash The hash of the market to process.
     * @param _depositor The address of the depositor.
     * @param _composeMsg The current compose message to be updated.
     * @return The updated compose message and the depositor's deposit amount.
     */
    function _processSingleTokenDepositor(bytes32 _marketHash, address _depositor, bytes memory _composeMsg) internal returns (uint256, bytes memory) {
        // Get amount deposited by the depositor (AP)
        uint256 depositAmount = marketHashToDepositorToAmountDeposited[_marketHash][_depositor];
        if (depositAmount == 0 || depositAmount > type(uint96).max) {
            return (0, _composeMsg); // Skip if no deposit or deposit amount exceeds limit
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
     * @return The updated compose messages and the amounts of tokens to bridge.
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
        returns (uint256, uint256, uint256, bytes memory, bytes memory)
    {
        // Get amount deposited by the depositor (AP)
        uint256 dt_DepositAmount = marketHashToDepositorToAmountDeposited[_marketHash][_depositor];

        // Calculate amount of each constituent to bridge
        uint256 tokenA_DepositAmount = dt_DepositAmount.mulWadDown(_amountOfTokenAPerDT);
        uint256 tokenB_DepositAmount = dt_DepositAmount.mulWadDown(_amountOfTokenBPerDT);

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

    /// @notice Deletes all Weiroll Wallet state and deposit amounts associated with this depositor for the specified market
    /// @param _marketHash The market hash to clear the depositor data for
    /// @param _depositor The depositor to clear the depositor data for
    function _clearDepositorData(bytes32 _marketHash, address _depositor) internal {
        // Mark all currently deposited Weiroll Wallets from this depositor as bridged
        address[] storage depositorWeirollWallets = marketHashToDepositorToWeirollWallets[_marketHash][_depositor];
        for (uint256 j = 0; j < depositorWeirollWallets.length; ++j) {
            // Set the amount deposited by the Weiroll Wallet to zero
            delete depositorToWeirollWalletToAmount[_depositor][depositorWeirollWallets[j]];
        }
        // Set length of currently deposited wallets list to zero
        delete marketHashToDepositorToWeirollWallets[_marketHash][_depositor];
        // Set the total deposit amount from this depositor (AP) to zero
        delete marketHashToDepositorToAmountDeposited[_marketHash][_depositor];
    }

    /// @dev Converts an address to bytes32.
    /// @param _addr The address to convert.
    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
