// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {RecipeKernelBase} from "src/base/RecipeKernelBase.sol";
import {IWeirollWallet} from "src/interfaces/IWeirollWallet.sol";
import {IStargate, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "src/interfaces/IStargate.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {OptionsBuilder} from "src/libraries/OptionsBuilder.sol";
import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title BerachainPredeposit
/// @author ShivaanshK, corddry
/// @notice A singleton contract for managing predeposits for Berachain on Ethereum
/// @notice This contract manages deposit tokens and bridging actions for all Berachain Royco markets
contract BerachainPredeposit is Ownable2Step {
    using SafeTransferLib for ERC20;
    using OptionsBuilder for bytes;

    /*//////////////////////////////////////////////////////////////
                               State
    //////////////////////////////////////////////////////////////*/

    // The destination endpoint ID for Berachain
    uint32 public berachainDstEid;

    // The ERC20 token => Address of the stargate bridge entrypoint for the specified token
    mapping(ERC20 => IStargate) public tokenToStargate;

    // The RecipeKernel keeping track of all markets and offers
    RecipeKernelBase recipeKernel;

    // Address of the ExecutionManager that will receive the tokens and payload on Berachain
    address executionManagerOnBerachain;

    // Royco Market ID => Address of the multisig between the market's IP and Berachain
    mapping(uint256 => address) public marketIdToMultisig;

    // Royco Market ID => Address of weiroll wallet (owned by depositor) => Amount deposited
    mapping(uint256 => mapping(address => uint256)) public marketIdToDepositorToAmountDeposited;

    // Royco Market ID => Green Light (indicating if funds are ready to bridge to Berachain for the given market)
    mapping(uint256 => bool) marketIdToGreenLight;

    /*//////////////////////////////////////////////////////////////
                            Events and Errors
    //////////////////////////////////////////////////////////////*/

    event UserDeposited(uint256 indexed marketId, address depositorWeirollWallet, uint256 amountDeposited);

    event UserWithdrawn(uint256 indexed marketId, address depositorWeirollWallet, uint256 amountWithdrawn);

    event BridgedToBerachain(bytes32 indexed guid, uint64 indexed nonce, uint256 marketId, uint256 amountBridged);

    error ArrayLengthMismatch();

    error GreenLightNotGiven();

    error UnauthorizedMultisigForThisMarket();

    error UnauthorizedIPForThisMarket();

    error InsufficientEthForBridge();

    error FailedToBridge();

    /*//////////////////////////////////////////////////////////////
                               Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier onlyMultisig(uint256 _marketId) {
        // Check if caller is the multisig between the market's IP and Berachain
        require(marketIdToMultisig[_marketId] == msg.sender, UnauthorizedMultisigForThisMarket());
        _;
    }

    modifier greenLightGiven(uint256 _marketId) {
        // Check if green light has been given for the specified market
        require(marketIdToGreenLight[_marketId], GreenLightNotGiven());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               Functions
    //////////////////////////////////////////////////////////////*/

    /// @param _owner The address of the owner of the contract
    /// @param _berachainDstEid Destination endpoint ID for Berachain
    /// @param _predepositTokens The tokens to bridge to berachain
    /// @param _stargates The corresponding stargate instances for each bridgable token
    /// @param _recipeKernel Address of the recipe kernel used to create the Royco markets
    constructor(
        address _owner,
        uint32 _berachainDstEid,
        ERC20[] memory _predepositTokens,
        IStargate[] memory _stargates,
        RecipeKernelBase _recipeKernel
    ) Ownable(_owner) {
        require(_predepositTokens.length == _stargates.length, ArrayLengthMismatch());

        // Initialize the contract state
        for (uint256 i = 0; i < _predepositTokens.length; ++i) {
            tokenToStargate[_predepositTokens[i]] = _stargates[i];
        }
        berachainDstEid = _berachainDstEid;
        recipeKernel = _recipeKernel;
    }

    /// @param _berachainDstEid Destination endpoint ID for Berachain
    function setBerachainDstEid(uint32 _berachainDstEid) external onlyOwner {
        berachainDstEid = _berachainDstEid;
    }

    /// @param _token Token to set a stargate instance for
    /// @param _stargate Stargate instance to set for the specified token
    function setStargate(ERC20 _token, IStargate _stargate) external onlyOwner {
        tokenToStargate[_token] = _stargate;
    }

    /// @param _recipeKernel Address of the new recipe kernel used to create Royco markets
    function setRecipeKernel(address _recipeKernel) external onlyOwner {
        recipeKernel = RecipeKernelBase(_recipeKernel);
    }

    /// @param _executionManagerOnBerachain Address of the new ExecutionManager that will receive the tokens and payload on Berachain
    function setExecutionManager(address _executionManagerOnBerachain) external onlyOwner {
        executionManagerOnBerachain = _executionManagerOnBerachain;
    }

    /// @param _marketId The Royco market ID to set the multisig for
    /// @param _multisig The address of the multisig contract between the market's IP and Berachain
    function setMulitsig(uint256 _marketId, address _multisig) external onlyOwner {
        marketIdToMultisig[_marketId] = _multisig;
    }

    /// @param _marketId The Royco market ID to set the greenlight for
    /// @param _greenLightStatus Boolean indicating if funds are ready to bridge to Berachain for the given market
    function setGreenLight(uint256 _marketId, bool _greenLightStatus) external onlyMultisig(_marketId) {
        marketIdToGreenLight[_marketId] = _greenLightStatus;
    }

    /// @dev Called by the deposit script from the depositors weiroll wallet
    function deposit() external {
        // Instantiate weiroll wallet
        IWeirollWallet wallet = IWeirollWallet(payable(msg.sender));
        // Get relevant information about the depositor
        uint256 targetMarketId = wallet.marketId();
        uint256 amountDeposited = wallet.amount();

        // Transfer the deposit amount and update accounting for the depositor's weiroll wallet
        (ERC20 marketInputToken,,,,,) = recipeKernel.marketIDToWeirollMarket(targetMarketId);
        marketInputToken.safeTransferFrom(msg.sender, address(this), amountDeposited);
        marketIdToDepositorToAmountDeposited[targetMarketId][msg.sender] = amountDeposited;

        // Emit deposit event for protocols to index
        emit UserDeposited(targetMarketId, msg.sender, amountDeposited);
    }

    /// @dev Called by the withdraw script from the depositor's weiroll wallet if the depositor forfeits rewards and backs out
    function withdraw() external {
        // Instantiate weiroll wallet
        IWeirollWallet wallet = IWeirollWallet(payable(msg.sender));
        // Get relevant information about the depositor
        uint256 targetMarketId = wallet.marketId();
        uint256 amountToWithdraw = wallet.amount();

        // Update accounting for the depositor's weiroll wallet and transfer the deposit amount back to the weiroll wallet
        delete marketIdToDepositorToAmountDeposited[targetMarketId][msg.sender];
        (ERC20 marketInputToken,,,,,) = recipeKernel.marketIDToWeirollMarket(targetMarketId);
        marketInputToken.safeTransferFrom(address(this), msg.sender, amountToWithdraw);

        // Emit withdrawal event for protocols to index
        emit UserWithdrawn(targetMarketId, msg.sender, amountToWithdraw);
    }

    /// @dev Called to bridge depositors from Ethereum to Berachain
    /// @dev Green light must be given before calling
    /// @param _marketId The market ID of the market to bridge tokens for
    /// @param _executorGasLimit The gas limit of the executor the destination chain
    /// @param _depositorWeirollWallets The addresses of the weiroll wallets used to deposit into the market
    function bridge(uint8 _marketId, uint128 _executorGasLimit, address[] calldata _depositorWeirollWallets)
        external
        payable
        greenLightGiven(_marketId)
    {
        /*
        Per Bridge TX Payload:
            marketID - uint8 - 1 byte

        Per AP Payload:
            AP address - address - 20 bytes
            Amount Deposited - uint96 - 12 bytes
            Remaining wallet locktime - uint32 - 4 bytes
            Total: 40 bytes
        */

        // Append marketID to the bridge tx's compose message
        bytes memory composeMsg;
        composeMsg[0] = bytes1(_marketId);

        // Keep track of total deposits being bridged
        uint256 totalAmountToBridge;

        for (uint256 i = 0; i < _depositorWeirollWallets.length; ++i) {
            IWeirollWallet wallet = IWeirollWallet(payable(_depositorWeirollWallets[i]));

            // Add amount deposited by the weiroll wallet to the amount to bridge
            uint96 depositAmount = uint96(marketIdToDepositorToAmountDeposited[_marketId][_depositorWeirollWallets[i]]);
            totalAmountToBridge += depositAmount;
            delete marketIdToDepositorToAmountDeposited[_marketId][_depositorWeirollWallets[i]];

            // Encode the per AP payload
            bytes memory apPayload =
                abi.encodePacked(wallet.owner(), depositAmount, uint32((wallet.lockedUntil() - block.timestamp)));
            // Append the AP's payload to the compose message
            composeMsg = abi.encodePacked(composeMsg, apPayload);
        }

        // Marshal the bridging params
        SendParam memory sendParam = SendParam({
            dstEid: berachainDstEid,
            to: _addressToBytes32(executionManagerOnBerachain),
            amountLD: totalAmountToBridge,
            minAmountLD: totalAmountToBridge,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _executorGasLimit, 0), // compose gas limit
            composeMsg: composeMsg,
            oftCmd: ""
        });

        // Get the market's input token and the corresponding stargate instance
        (ERC20 marketInputToken,,,,,) = recipeKernel.marketIDToWeirollMarket(_marketId);
        IStargate stargate = tokenToStargate[marketInputToken];

        // Get a quote for the fees taken on bridge
        MessagingFee memory messagingFee = stargate.quoteSend(sendParam, false);
        uint256 nativeBridgingFee = messagingFee.nativeFee;
        // Check that sender sent enough ETH to cover the fee
        require(msg.value >= nativeBridgingFee, InsufficientEthForBridge());

        // Approve stargate to bridge the tokens
        marketInputToken.safeApprove(address(stargate), 0);
        marketInputToken.safeApprove(address(stargate), totalAmountToBridge);

        // Execute the bridge transaction
        (MessagingReceipt memory msgReceipt, OFTReceipt memory bridgeReceipt,) =
            stargate.sendToken{value: nativeBridgingFee}(sendParam, messagingFee, address(this));
        require(totalAmountToBridge == bridgeReceipt.amountReceivedLD, FailedToBridge());

        // Refund any excess ETH to sender
        if (msg.value > nativeBridgingFee) {
            payable(msg.sender).transfer(msg.value - nativeBridgingFee);
        }

        emit BridgedToBerachain(msgReceipt.guid, msgReceipt.nonce, _marketId, totalAmountToBridge);
    }

    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
