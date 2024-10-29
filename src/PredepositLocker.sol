// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { RecipeMarketHubBase, ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { WeirollWallet } from "@royco/src/WeirollWallet.sol";
import { IStargate, IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt } from "src/interfaces/IStargate.sol";
import { OptionsBuilder } from "src/libraries/OptionsBuilder.sol";
import { Ownable2Step, Ownable } from "@openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title PredepositLocker
/// @notice A singleton contract for managing predeposits for the destination chain on the source chain.
/// @notice Manages deposits, withdrawals, and bridging deposits for all predeposit markets.
contract PredepositLocker is Ownable2Step, ReentrancyGuardTransient {
    using SafeTransferLib for ERC20;
    using OptionsBuilder for bytes;

    // Limit for how many depositers can be bridged in a single transaction
    // At this limit, ~10m gas will be consumed to execute lzCompose logic on the destination's PredepositExecutor
    uint256 public constant MAX_DEPOSITORS_PER_BRIDGE = 100;

    /*//////////////////////////////////////////////////////////////
                                   State
    //////////////////////////////////////////////////////////////*/

    /// @notice The RecipeMarketHub keeping track of all markets and offers.
    RecipeMarketHubBase public immutable RECIPE_MARKET_HUB;

    // Address of wBTC on source chain
    // Bridge needs to be handled through LayerZero OFT instead of Stargate
    address public immutable WBTC_ADDRESS;

    // Address of wBTC OFT Adapter on source chain - Facilitates wBTC bridging
    IOFT public immutable WBTC_OFT_ADAPTER;

    /// @notice The LayerZero endpoint ID for the destination chain.
    uint32 public dstChainLzEid;

    /// @notice Mapping of ERC20 token to its corresponding Stargate bridge entrypoint.
    mapping(ERC20 => IStargate) public tokenToStargatePool;

    /// @notice Address of the PredepositExecutor on the destination chain.
    address public predepositExecutor;

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

    /// @notice Error emitted when setting an OFT adapter for wBTC that doesn't match the OFT's underlying token
    error InvalidOFTAdapterForWBTC();

    /// @notice Error emitted when setting a stargate pool for a token that doesn't match the pool's underlying token
    error InvalidStargatePoolForToken();

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

    /// @notice Error emitted when insufficient ETH is provided for the bridge fee.
    error InsufficientEthForBridge();

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

    /// @notice Constructor to initialize the contract.
    /// @param _owner The address of the owner of the contract.
    /// @param _dstChainLzEid Destination LayerZero endpoint ID for the destination chain.
    /// @param _predepositExecutor Address of the the PredepositExecutor on the destination chain.
    /// @param _wBTC_Address The address of wBTC on the source chain.
    /// @param _wBTC_OFT_Adapter The LayerZero wBTC OFT Adapter on the source chain.
    /// @param _recipe_market_hub Address of the recipe market hub used to create markets on the source chain.
    /// @param _stargatePredepositTokens The tokens to bridge to the destination chain using stargate on the source chain.
    /// @param _stargatePools The corresponding stargate pool instances for each stargate supported token on the source chain.
    constructor(
        address _owner,
        uint32 _dstChainLzEid,
        address _predepositExecutor,
        address _wBTC_Address,
        IOFT _wBTC_OFT_Adapter,
        RecipeMarketHubBase _recipe_market_hub,
        ERC20[] memory _stargatePredepositTokens,
        IStargate[] memory _stargatePools
    )
        Ownable(_owner)
    {
        // Check that each token that will be bridged using stargate has a corresponding stargate pool
        require(_stargatePredepositTokens.length == _stargatePools.length, ArrayLengthMismatch());
        // Check that wBTC OFT Adapter is valid
        require(_wBTC_OFT_Adapter.token() == address(_wBTC_Address), InvalidOFTAdapterForWBTC());

        // Set immutable variables
        RECIPE_MARKET_HUB = _recipe_market_hub;
        WBTC_ADDRESS = _wBTC_Address;
        WBTC_OFT_ADAPTER = _wBTC_OFT_Adapter;

        // Initialize the contract state
        for (uint256 i = 0; i < _stargatePredepositTokens.length; ++i) {
            // Check that the token has a valid corresponding stargate pool
            require(_stargatePools[i].token() == address(_stargatePredepositTokens[i]), InvalidStargatePoolForToken());
            tokenToStargatePool[_stargatePredepositTokens[i]] = _stargatePools[i];
        }
        dstChainLzEid = _dstChainLzEid;
        predepositExecutor = _predepositExecutor;
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
            WeirollWallet wallet = WeirollWallet(_depositorWeirollWallets[i]);

            // Get deposited amount
            uint96 depositAmount = uint96(marketHashToDepositorToAmountDeposited[_marketHash][_depositorWeirollWallets[i]]);
            if (depositAmount == 0 || depositAmount > type(uint96).max) {
                continue; // Skip if didn't deposit or deposit amount is too much to bridge
            }
            totalAmountToBridge += depositAmount;
            delete marketHashToDepositorToAmountDeposited[_marketHash][_depositorWeirollWallets[i]];

            // Encode depositor's payload
            bytes32 apPayload = bytes32(abi.encodePacked(wallet.owner(), depositAmount));
            // Concatenate depositor's payload with compose message
            composeMsg = abi.encodePacked(composeMsg, apPayload);
        }

        // Prepare SendParam for bridging
        SendParam memory sendParam = SendParam({
            dstEid: dstChainLzEid,
            to: _addressToBytes32(predepositExecutor),
            amountLD: totalAmountToBridge,
            minAmountLD: totalAmountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _executorGasLimit, 0),
            composeMsg: composeMsg,
            oftCmd: ""
        });

        // Get the market's input token
        (, ERC20 marketInputToken,,,,,) = RECIPE_MARKET_HUB.marketHashToWeirollMarket(_marketHash);

        // Declare variables used for bridge
        MessagingFee memory messagingFee;
        MessagingReceipt memory messageReceipt;
        OFTReceipt memory bridgeReceipt;

        if (address(marketInputToken) == WBTC_ADDRESS) {
            // If the token to bridge is wBTC use the LZ OFT adapter
            // Get fee quote for bridging
            messagingFee = WBTC_OFT_ADAPTER.quoteSend(sendParam, false);
            require(msg.value >= messagingFee.nativeFee, InsufficientEthForBridge());

            // Approve the wBTC OFT adapter to bridge tokens
            marketInputToken.safeApprove(address(WBTC_OFT_ADAPTER), totalAmountToBridge);

            // Execute the bridge transaction
            (messageReceipt, bridgeReceipt) = WBTC_OFT_ADAPTER.send{ value: messagingFee.nativeFee }(sendParam, messagingFee, address(this));
        } else {
            // If the token to bridge isn't wBTC use the corresponding Stargate Pool
            IStargate stargate = tokenToStargatePool[marketInputToken];

            // Get fee quote for bridging
            messagingFee = stargate.quoteSend(sendParam, false);
            require(msg.value >= messagingFee.nativeFee, InsufficientEthForBridge());

            // Approve Stargate to bridge tokens
            marketInputToken.safeApprove(address(stargate), totalAmountToBridge);

            // Execute the bridge transaction
            (messageReceipt, bridgeReceipt,) = stargate.sendToken{ value: messagingFee.nativeFee }(sendParam, messagingFee, address(this));
        }

        // Ensure that all deposits were bridged
        require(totalAmountToBridge == bridgeReceipt.amountReceivedLD, FailedToBridgeAllDeposits());

        // Refund excess ETH
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

    /// @notice Sets the Stargate instance for a given token.
    /// @param _token Token to set a Stargate pool instance for.
    /// @param _stargatePool Stargate pool instance to set for the specified token.
    function setStargatePool(ERC20 _token, IStargate _stargatePool) external onlyOwner {
        require(_stargatePool.token() == address(_token), InvalidStargatePoolForToken());
        tokenToStargatePool[_token] = _stargatePool;
    }

    /// @notice Sets the PredepositExecutor address.
    /// @param _predepositExecutor Address of the new PredepositExecutor.
    function setPredepositExecutor(address _predepositExecutor) external onlyOwner {
        predepositExecutor = _predepositExecutor;
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
