// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {RecipeKernelBase} from "src/base/RecipeKernelBase.sol";
import {IWeirollWallet} from "src/interfaces/IWeirollWallet.sol";
import {IStargate, IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "src/interfaces/IStargate.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {Ownable2Step, Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title BerachainPredeposit
/// @author ShivaanshK, corddry
/// @notice A singleton contract for managing predeposits for Berachain on Ethereum
/// @notice This contract manages deposit tokens and bridging actions for all Berachain Royco markets
contract BerachainPredeposit is Ownable2Step {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                               State
    //////////////////////////////////////////////////////////////*/

    // The address of the stargate bridge entrypoint
    IStargate stargate;

    // The RecipeKernel keeping track of all markets and offers
    RecipeKernelBase recipeKernel;

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

    error GreenLightNotGiven();

    error UnauthorizedMultisigForThisMarket();

    error UnauthorizedIPForThisMarket();

    error InsufficientEthForBridge();

    /*//////////////////////////////////////////////////////////////
                               Modifiers
    //////////////////////////////////////////////////////////////*/

    modifier onlyMultisig(uint256 _marketId) {
        // Check if the "bridger" is the IP for the specified market
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

    /// @param _owner Address of the owner of the contract
    /// @param _stargate Address of the stargate bridge entrypoint
    constructor(address _owner, address _stargate, address _recipeKernel) Ownable(_owner) {
        stargate = IStargate(_stargate);
        recipeKernel = RecipeKernelBase(_recipeKernel);
    }

    /// @param _stargate Address of the new stargate bridge entrypoint
    function setStargate(address _stargate) external onlyOwner {
        stargate = IStargate(_stargate);
    }

    /// @param _recipeKernel Address of the new recipe kernel used to create Royco markets
    function setRecipeKernel(address _recipeKernel) external onlyOwner {
        recipeKernel = RecipeKernelBase(_recipeKernel);
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

    // per user in payload
    // AP address - address
    // deposit amount - uint64
    // remaining locktime - uint32

    // 1 per payload bridged
    // marketID - uint8

    // receivePredeposit

    /// @dev Called by the market's IP to bridges depositors from Ethereum to Berachain
    /// @dev Green light must be given for this IP before calling
    function bridge(uint256 _marketId, address[] calldata _depositorWeirollWallets)
        external
        payable
        greenLightGiven(_marketId)
    {
        SendParam memory sendParam = SendParam({
            dstEid: _dstEid,
            to: addressToBytes32(_receiver),
            amountLD: 0,
            minAmountLD: 0,
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: ""
        });

        for (uint256 i = 0; i < _depositorWeirollWallets.length; ++i) {}
        // uint256 amount = marketIdToDepositorToAmountDeposited[targetMarketID][user];

        // // generated below
        // marketIdToDepositorToAmountDeposited[targetMarketID][user] = 0;
        // // Prepare the transaction parameters
        // (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) =
        //     integration.prepareTakeTaxi(stargate, targetMarketID, amount, user); // TODO: errors in params

        // // Ensure enough ETH is sent to cover the cost of bridging
        // require(msg.value >= valueToSend, InsufficientEthForBridge());

        // // Approve the Stargate contract to spend tokens
        // ERC20 token = marketIDToDepositToken[targetMarketID];
        // token.approve(stargate, amount);

        // // Execute the omnichain transaction
        // IStargate(stargate).sendToken{value: valueToSend}(sendParam, messagingFee, user);

        // // Refund any excess ETH
        // if (msg.value > valueToSend) {
        //     payable(msg.sender).transfer(msg.value - valueToSend);
        // }
    }
}
