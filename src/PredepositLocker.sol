// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {RecipeKernelBase} from "src/base/RecipeKernelBase.sol";
import {IWeirollWallet} from "src/interfaces/IWeirollWallet.sol";
import {IStargate, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "src/interfaces/IStargate.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {OptionsBuilder} from "src/libraries/OptionsBuilder.sol";
import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title PredepositLocker
/// @notice A singleton contract for managing predeposits for the destination chain on Ethereum.
/// @notice Manages deposit tokens and bridging actions for all relevant predeposit Royco markets.
contract PredepositLocker is Ownable2Step {
    using SafeTransferLib for ERC20;
    using OptionsBuilder for bytes;

    /*//////////////////////////////////////////////////////////////
                                   State
    //////////////////////////////////////////////////////////////*/

    /// @notice The destination endpoint ID for the destination chain.
    uint32 public chainDstEid;

    /// @notice Mapping of ERC20 token to its corresponding Stargate bridge entrypoint.
    mapping(ERC20 => IStargate) public tokenToStargate;

    /// @notice The RecipeKernel keeping track of all markets and offers.
    RecipeKernelBase public recipeKernel;

    /// @notice Address of the PredepositExecutor on the destination chain.
    address public predepositExecutor;

    /// @notice Mapping from Royco Market ID to the multisig address between the market's IP and the destination chain.
    mapping(uint256 => address) public marketIdToMultisig;

    /// @notice Mapping from Market ID to depositor's Weiroll wallet address to amount deposited.
    mapping(uint256 => mapping(address => uint256)) public marketIdToDepositorToAmountDeposited;

    /// @notice Mapping from Market ID to green light status for bridging funds.
    mapping(uint256 => bool) public marketIdToGreenLight;

    /*//////////////////////////////////////////////////////////////
                                Events and Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits funds.
    event UserDeposited(uint256 indexed marketId, address depositorWeirollWallet, uint256 amountDeposited);

    /// @notice Emitted when a user withdraws funds.
    event UserWithdrawn(uint256 indexed marketId, address depositorWeirollWallet, uint256 amountWithdrawn);

    /// @notice Emitted when funds are bridged to the destination chain.
    event BridgedToDestinationChain(
        bytes32 indexed guid, uint64 indexed nonce, uint256 marketId, uint256 amountBridged
    );

    /// @notice Error emitted when array lengths mismatch.
    error ArrayLengthMismatch();

    /// @notice Error emitted when green light is not given for bridging.
    error GreenLightNotGiven();

    /// @notice Error emitted when the caller is not the authorized multisig for the market.
    error UnauthorizedMultisigForThisMarket();

    /// @notice Error emitted when insufficient ETH is provided for the bridge fee.
    error InsufficientEthForBridge();

    /// @notice Error emitted when bridging all the specified deposits fails.
    error FailedToBridgeAllDeposits();

    /*//////////////////////////////////////////////////////////////
                                   Modifiers
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier to ensure the caller is the authorized multisig for the market.
    modifier onlyMultisig(uint256 _marketId) {
        require(marketIdToMultisig[_marketId] == msg.sender, UnauthorizedMultisigForThisMarket());
        _;
    }

    /// @dev Modifier to check if green light is given for bridging.
    modifier greenLightGiven(uint256 _marketId) {
        require(marketIdToGreenLight[_marketId], GreenLightNotGiven());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                   Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor to initialize the contract.
    /// @param _owner The address of the owner of the contract.
    /// @param _chainDstEid Destination endpoint ID for the destination chain.
    /// @param _predepositExecutor Address of the the PredepositExecutor on the destination chain.
    /// @param _predepositTokens The tokens to bridge to the destination chain.
    /// @param _stargates The corresponding Stargate instances for each bridgable token.
    /// @param _recipeKernel Address of the recipe kernel used to create the Royco markets.
    constructor(
        address _owner,
        uint32 _chainDstEid,
        address _predepositExecutor,
        ERC20[] memory _predepositTokens,
        IStargate[] memory _stargates,
        RecipeKernelBase _recipeKernel
    ) Ownable(_owner) {
        require(_predepositTokens.length == _stargates.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _predepositTokens.length; ++i) {
            tokenToStargate[_predepositTokens[i]] = _stargates[i];
        }
        chainDstEid = _chainDstEid;
        predepositExecutor = _predepositExecutor;
        recipeKernel = _recipeKernel;
    }

    /// @notice Sets the destination endpoint ID for the destination chain.
    /// @param _chainDstEid Destination endpoint ID for the destination chain.
    function setDestinationChainDstEid(uint32 _chainDstEid) external onlyOwner {
        chainDstEid = _chainDstEid;
    }

    /// @notice Sets the Stargate instance for a given token.
    /// @param _token Token to set a Stargate instance for.
    /// @param _stargate Stargate instance to set for the specified token.
    function setStargate(ERC20 _token, IStargate _stargate) external onlyOwner {
        tokenToStargate[_token] = _stargate;
    }

    /// @notice Sets the recipe kernel contract.
    /// @param _recipeKernel Address of the new recipe kernel used to create Royco markets.
    function setRecipeKernel(address _recipeKernel) external onlyOwner {
        recipeKernel = RecipeKernelBase(_recipeKernel);
    }

    /// @notice Sets the PredepositExecutor address.
    /// @param _predepositExecutor Address of the new PredepositExecutor.
    function setPredepositExecutor(address _predepositExecutor) external onlyOwner {
        predepositExecutor = _predepositExecutor;
    }

    /// @notice Sets the multisig address for a market.
    /// @param _marketId The Royco market ID to set the multisig for.
    /// @param _multisig The address of the multisig contract between the market's IP and the destination chain.
    function setMulitsig(uint256 _marketId, address _multisig) external onlyOwner {
        marketIdToMultisig[_marketId] = _multisig;
    }

    /// @notice Sets the green light status for a market.
    /// @param _marketId The Royco market ID to set the green light for.
    /// @param _greenLightStatus Boolean indicating if funds are ready to bridge.
    function setGreenLight(uint256 _marketId, bool _greenLightStatus) external onlyMultisig(_marketId) {
        marketIdToGreenLight[_marketId] = _greenLightStatus;
    }

    /// @notice Called by the deposit script from the depositor's Weiroll wallet.
    function deposit() external {
        // Instantiate Weiroll wallet
        IWeirollWallet wallet = IWeirollWallet(payable(msg.sender));
        // Get depositor's market ID and amount
        uint256 targetMarketId = wallet.marketId();
        uint256 amountDeposited = wallet.amount();

        // Transfer the deposit amount and update accounting
        (ERC20 marketInputToken,,,,,) = recipeKernel.marketIDToWeirollMarket(targetMarketId);
        marketInputToken.safeTransferFrom(msg.sender, address(this), amountDeposited);
        marketIdToDepositorToAmountDeposited[targetMarketId][msg.sender] = amountDeposited;

        // Emit deposit event
        emit UserDeposited(targetMarketId, msg.sender, amountDeposited);
    }

    /// @notice Called by the withdraw script from the depositor's Weiroll wallet.
    function withdraw() external {
        // Instantiate Weiroll wallet
        IWeirollWallet wallet = IWeirollWallet(payable(msg.sender));
        // Get depositor's market ID and amount
        uint256 targetMarketId = wallet.marketId();
        uint256 amountToWithdraw = wallet.amount();

        // Update accounting and transfer back the amount
        delete marketIdToDepositorToAmountDeposited[targetMarketId][msg.sender];
        (ERC20 marketInputToken,,,,,) = recipeKernel.marketIDToWeirollMarket(targetMarketId);
        marketInputToken.safeTransferFrom(address(this), msg.sender, amountToWithdraw);

        // Emit withdrawal event
        emit UserWithdrawn(targetMarketId, msg.sender, amountToWithdraw);
    }

    /// @notice Bridges depositors from Ethereum to the destination chain.
    /// @dev Green light must be given before calling.
    /// @param _marketId The market ID to bridge tokens for.
    /// @param _executorGasLimit The gas limit of the executor on the destination chain.
    /// @param _depositorWeirollWallets The addresses of the Weiroll wallets used to deposit.
    function bridge(uint256 _marketId, uint128 _executorGasLimit, address payable[] calldata _depositorWeirollWallets)
        external
        payable
        greenLightGiven(_marketId)
    {
        /*
        Payload Structure:
            - marketID: uint256 (32 byte)
        Per Depositor:
            - AP address: address (20 bytes)
            - Amount Deposited: uint96 (12 bytes)
            Total per depositor: 32 bytes
        */

        // Initialize compose message with market ID
        bytes memory composeMsg = abi.encodePacked(bytes32(_marketId));

        // Keep track of total amount of deposits to bridge
        uint256 totalAmountToBridge;

        for (uint256 i = 0; i < _depositorWeirollWallets.length; ++i) {
            IWeirollWallet wallet = IWeirollWallet(_depositorWeirollWallets[i]);

            // Get deposited amount
            uint96 depositAmount = uint96(marketIdToDepositorToAmountDeposited[_marketId][_depositorWeirollWallets[i]]);
            if (depositAmount == 0) {
                continue; // Skip if didn't deposit
            }
            totalAmountToBridge += depositAmount;
            delete marketIdToDepositorToAmountDeposited[_marketId][_depositorWeirollWallets[i]];

            // Encode depositor's payload
            bytes memory apPayload = abi.encodePacked(wallet.owner(), depositAmount);
            // Concatenate depositor's payload with compose message
            composeMsg = abi.encodePacked(composeMsg, apPayload);
        }

        // Prepare SendParam for bridging
        SendParam memory sendParam = SendParam({
            dstEid: chainDstEid,
            to: _addressToBytes32(predepositExecutor),
            amountLD: totalAmountToBridge,
            minAmountLD: totalAmountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _executorGasLimit, 0),
            composeMsg: composeMsg,
            oftCmd: ""
        });

        // Get the market's input token and Stargate instance
        (ERC20 marketInputToken,,,,,) = recipeKernel.marketIDToWeirollMarket(_marketId);
        IStargate stargate = tokenToStargate[marketInputToken];

        // Get fee quote for bridging
        MessagingFee memory messagingFee = stargate.quoteSend(sendParam, false);
        uint256 nativeBridgingFee = messagingFee.nativeFee;
        require(msg.value >= nativeBridgingFee, InsufficientEthForBridge());

        // Approve Stargate to bridge tokens
        marketInputToken.safeApprove(address(stargate), 0);
        marketInputToken.safeApprove(address(stargate), totalAmountToBridge);

        // Execute bridge transaction
        (MessagingReceipt memory msgReceipt, OFTReceipt memory bridgeReceipt,) =
            stargate.sendToken{value: nativeBridgingFee}(sendParam, messagingFee, address(this));
        // Ensure that all deposits were bridged
        require(totalAmountToBridge == bridgeReceipt.amountReceivedLD, FailedToBridgeAllDeposits());

        // Refund excess ETH
        if (msg.value > nativeBridgingFee) {
            payable(msg.sender).transfer(msg.value - nativeBridgingFee);
        }

        // Emit event to keep track of bridged deposits
        emit BridgedToDestinationChain(msgReceipt.guid, msgReceipt.nonce, _marketId, totalAmountToBridge);
    }

    /// @dev Converts an address to bytes32.
    /// @param _addr The address to convert.
    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
