// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { IStargate } from "./interfaces/IStargate.sol";
import { MessagingFee, OFTReceipt, SendParam } from "./interfaces/IOFT.sol";

contract StargateIntegration {
    function prepareTakeTaxi(
        address _stargate,
        uint32 _dstEid,
        uint256 _amount,
        address _receiver
    ) external view returns (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) {
        sendParam = SendParam({
            dstEid: _dstEid,
            to: addressToBytes32(_receiver),
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: new bytes(0),
            composeMsg: new bytes(0),
            oftCmd: ""
        });

        IStargate stargate = IStargate(_stargate);

        (, , OFTReceipt memory receipt) = stargate.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        messagingFee = stargate.quoteSend(sendParam, false);
        valueToSend = messagingFee.nativeFee;

        if (stargate.token() == address(0x0)) {
            valueToSend += sendParam.amountLD;
        }
    }

    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}

contract PredepositWallet {
    StargateIntegration public integration;
    address public stargate;
    address public sourceChainPoolToken;

    constructor(address _stargate, address _sourceChainPoolToken) {
        integration = new StargateIntegration();
        stargate = _stargate;
        sourceChainPoolToken = _sourceChainPoolToken;
    }

    function executeOmnichainTransaction(uint32 destinationEndpointId, uint256 amount, address alice) external payable {
        // Approve the Stargate contract to spend tokens
        IERC20(sourceChainPoolToken).approve(stargate, amount);

        // Prepare the transaction parameters
        (uint256 valueToSend, SendParam memory sendParam, MessagingFee memory messagingFee) =
            integration.prepareTakeTaxi(stargate, destinationEndpointId, amount, alice);

        // Ensure enough ETH is sent to cover the transaction
        require(msg.value >= valueToSend, "Insufficient ETH sent");

        // Execute the omnichain transaction
        IStargate(stargate).sendToken{ value: valueToSend }(sendParam, messagingFee, alice);

        // Refund any excess ETH
        if (msg.value > valueToSend) {
            payable(msg.sender).transfer(msg.value - valueToSend);
        }
    }
}