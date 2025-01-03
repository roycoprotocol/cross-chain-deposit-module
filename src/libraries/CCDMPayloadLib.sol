// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title CCDMPayloadLib
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A library for encoding and decoding CCDM payloads
library CCDMPayloadLib {
    /*//////////////////////////////////////////////////////////////
                    CCDM Payload Structure
               -------------------------------
                Per Payload (first 65 bytes):
                    - Market Hash: bytes32 (32 bytes)
                    - CCDM Nonce: uint256 (32 bytes)
                    - Number of Tokens Bridged: uint8 (1 byte)
                Per Depositor (following 32 byte blocks):
                    - Depositor / AP address: address (20 bytes)
                    - Amount Deposited: uint96 (12 bytes)
    //////////////////////////////////////////////////////////////*/

    /// @notice Size of payload metadata and offset to the first depositor in a CCDM payload.
    // (32 bytes for the Market Hash + 32 bytes for the CCDM Nonce + 1 byte for the number of tokens bridged) = 65 bytes
    uint256 internal constant METADATA_SIZE = 65;

    /// @notice Bytes used per depositor position in the payload
    // (20 bytes for depositor address + 12 bytes for the corresponding deposit amount) = 32 bytes
    uint256 internal constant BYTES_PER_DEPOSITOR = 32;

    /*//////////////////////////////////////////////////////////////
                            Encoding Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes a compose message for CCDM.
    /// @param _numDepositors The number of depositors that will be bridged using this compose message.
    /// @param _marketHash The Royco market hash associated with the deposits.
    /// @param _ccdmNonce The ccdmNonce associated with the DUAL_OR_LP_TOKEN deposits.
    /// @param _numTokensBridged The number of input tokens bridged for the destination campaign.
    /// @return composeMsg The compose message initialized with the params.
    function initComposeMsg(
        uint256 _numDepositors,
        bytes32 _marketHash,
        uint256 _ccdmNonce,
        uint8 _numTokensBridged
    )
        internal
        pure
        returns (bytes memory composeMsg)
    {
        uint256 msgSizeInBytes = METADATA_SIZE + (_numDepositors * BYTES_PER_DEPOSITOR);
        composeMsg = new bytes(msgSizeInBytes);
        assembly ("memory-safe") {
            let ptr := add(composeMsg, 32) // Pointer to the start of the data in _composeMsg
            mstore(ptr, _marketHash) // Write _marketHash (32 bytes)
            mstore(add(ptr, 32), _ccdmNonce) // Write _ccdmNonce (32 bytes)
            mstore8(add(ptr, 64), _numTokensBridged) // Write _numTokensBridged (1 byte)
        }
    }

    /// @dev Writes a depositor and their amount directly into the _composeMsg at a particular index.
    /// @dev The index must be within the bounds of the payload size.
    /// @param _composeMsg The bytes array to which the depositor information will be written.
    /// @param _depositor The depositor's address.
    /// @param _depositAmount The amount deposited by the depositor.
    function writeDepositor(bytes memory _composeMsg, uint256 _depositorIndex, address _depositor, uint96 _depositAmount) internal pure {
        assembly ("memory-safe") {
            // The memory pointer for the depositor at this index
            let ptr := add(_composeMsg, add(32, add(METADATA_SIZE, mul(_depositorIndex, BYTES_PER_DEPOSITOR))))
            mstore(ptr, or(shl(96, _depositor), _depositAmount)) // Write _depositor and _depositAmount as 1 word
        }
    }

    /// @dev Resizes the compose message by reducing its length.
    /// @dev The size of the message can only be REDUCED.
    /// @param _composeMsg The bytes array containing the marshaled depositor information.
    /// @param _numDepositors The number of depositors to resize the compose message to accomodate.
    function resizeComposeMsg(bytes memory _composeMsg, uint256 _numDepositors) internal pure {
        uint256 msgSizeInBytes = METADATA_SIZE + (_numDepositors * BYTES_PER_DEPOSITOR);
        assembly ("memory-safe") {
            mstore(_composeMsg, msgSizeInBytes)
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Decoding Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Reads the metadata of the _composeMsg.
    /// @dev The metadata is the source market hash (first 32 bytes), ccdmNonce (following 32 bytes), numTokensBridged (following 1 byte).
    /// @param _composeMsg The compose message received in lzCompose.
    function readComposeMsgMetadata(bytes memory _composeMsg) internal pure returns (bytes32 sourceMarketHash, uint256 ccdmNonce, uint8 numTokensBridged) {
        assembly ("memory-safe") {
            // Pointer to the start of the compose message data (first 32 bytes is the length)
            let ptr := add(_composeMsg, 32)
            // Read the first 32 bytes as sourceMarketHash
            sourceMarketHash := mload(ptr)
            // Read the next 32 bytes as ccdmNonce
            ccdmNonce := mload(add(ptr, 32))
            // Read the next 1 byte as numTokensBridged
            numTokensBridged := shr(248, mload(add(ptr, 64)))
        }
    }

    /// @dev Reads an address from bytes at a specific offset.
    /// @param _composeMsg The compose message received in lzCompose
    /// @param _offset The offset to start reading from.
    /// @return addr The address read from the composeMsg at the specified offset.
    function readAddress(bytes memory _composeMsg, uint256 _offset) internal pure returns (address addr) {
        assembly ("memory-safe") {
            addr := shr(96, mload(add(add(_composeMsg, 32), _offset)))
        }
    }

    /// @dev Reads a uint96 from bytes at a specific offset.
    /// @param _composeMsg The compose message received in lzCompose
    /// @param _offset The offset to start reading from.
    /// @return value The uint96 value read from the composeMsg at the specified offset.
    function readUint96(bytes memory _composeMsg, uint256 _offset) internal pure returns (uint96 value) {
        assembly ("memory-safe") {
            value := shr(160, mload(add(add(_composeMsg, 32), _offset)))
        }
    }
}
