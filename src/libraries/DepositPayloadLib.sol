// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// An enumeration of deposit types supported by CCDM
enum DepositType {
    SINGLE_TOKEN, // Depositing a single OFT token on destination
    DUAL_OR_LP_TOKEN // Depositing 2 OFT tokens at a predefined ratio on destination

}

/// @title DepositPayloadLib
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A library for encoding and decoding CCDM payloads
library DepositPayloadLib {
    /*//////////////////////////////////////////////////////////////
                               Constants
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum size of a SINGLE_TOKEN Bridge Payload
    // (1 byte for DepositType + 32 bytes for sourceMarketHash + 32 bytes for single depositor payload) = 65 bytes
    uint256 internal constant MIN_SINGLE_TOKEN_PAYLOAD_SIZE = 65;

    /// @notice Offset to first depositor in a SINGLE_TOKEN payload
    // (1 byte for DepositType + 32 bytes for sourceMarketHash) = 33 bytes
    uint256 internal constant SINGLE_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET = 33;

    /// @notice Minimum size of a DUAL_OR_LP_TOKEN Bridge Payload
    // (1 byte for DepositType + 32 bytes for sourceMarketHash + 32 bytes for nonce + 32 bytes for single depositor payload) = 97 bytes
    uint256 internal constant MIN_DUAL_OR_LP_TOKEN_PAYLOAD_SIZE = 97;

    /// @notice Offset to first depositor in a DUAL_OR_LP_TOKEN payload
    // (1 byte for DepositType + 32 bytes for sourceMarketHash + 32 bytes for nonce) = 65 bytes
    uint256 internal constant DUAL_OR_LP_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET = 65;

    /// @notice Bytes used per depositor position in the payload
    // (20 bytes for depositor address + 12 bytes for the corresponding deposit amount) = 32 bytes
    uint256 internal constant BYTES_PER_DEPOSITOR = 32;

    /*//////////////////////////////////////////////////////////////
                            Encoding Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes a compose message for SINGLE_TOKEN cross-chain deposits in-place.
    /// @param _numDepositors The number of depositors that will be bridged using this compose message.
    /// @param _marketHash The Royco market hash associated with the deposits.
    /// @return composeMsg The compose message initialized with the params.
    function initSingleTokenComposeMsg(uint256 _numDepositors, bytes32 _marketHash) internal pure returns (bytes memory composeMsg) {
        uint256 msgSizeInBytes = SINGLE_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET + (_numDepositors * BYTES_PER_DEPOSITOR);
        composeMsg = new bytes(msgSizeInBytes);
        assembly ("memory-safe") {
            let ptr := add(composeMsg, 32) // Pointer to the start of the data in _composeMsg
            mstore8(ptr, 0) // Write DepositType (1 byte) - SINGLE_TOKEN
            mstore(add(ptr, 1), _marketHash) // Write _marketHash (32 bytes)
        }
    }

    /// @dev Initializes a compose message for DUAL_OR_LP_TOKEN cross-chain deposits in-place.
    /// @param _numDepositors The number of depositors that will be bridged using this compose message.
    /// @param _marketHash The Royco market hash associated with the deposits.
    /// @param _nonce The nonce associated with the DUAL_OR_LP_TOKEN deposits.
    /// @return composeMsg The compose message initialized with the params.
    function initDualOrLpTokenComposeMsg(uint256 _numDepositors, bytes32 _marketHash, uint256 _nonce) internal pure returns (bytes memory composeMsg) {
        uint256 msgSizeInBytes = DUAL_OR_LP_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET + (_numDepositors * BYTES_PER_DEPOSITOR);
        composeMsg = new bytes(msgSizeInBytes);
        assembly ("memory-safe") {
            let ptr := add(composeMsg, 32) // Pointer to the start of the data in _composeMsg
            mstore8(ptr, 1) // Write DepositType (1 byte) - DUAL_OR_LP_TOKEN
            mstore(add(ptr, 1), _marketHash) // Write _marketHash (32 bytes)
            mstore(add(ptr, 33), _nonce) // Write _nonce (32 bytes)
        }
    }

    /// @dev Writes a depositor and their amount directly into the _composeMsg at the end for SINGLE_TOKEN compose messages.
    /// @param _composeMsg The bytes array where the depositor info will be appended.
    /// @param _depositor The depositor's address.
    /// @param _depositAmount The amount deposited by the depositor.
    function writeDepositorToSingleTokenPayload(bytes memory _composeMsg, uint256 _depositorIndex, address _depositor, uint96 _depositAmount) internal pure {
        assembly ("memory-safe") {
            // The memory pointer for the depositor at this index
            let ptr := add(_composeMsg, add(32, add(SINGLE_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET, mul(_depositorIndex, BYTES_PER_DEPOSITOR))))
            mstore(ptr, or(shl(96, _depositor), _depositAmount)) // Write _depositor and _depositAmount
        }
    }

    /// @dev Writes a depositor and their amount directly into the _composeMsg at the end for DUAL_OR_LP_TOKEN compose messages.
    /// @param _composeMsg The bytes array where the depositor info will be appended.
    /// @param _depositor The depositor's address.
    /// @param _depositAmount The amount deposited by the depositor.
    function writeDepositorToDualOrLpTokenPayload(bytes memory _composeMsg, uint256 _depositorIndex, address _depositor, uint96 _depositAmount) internal pure {
        assembly ("memory-safe") {
            // The memory pointer for the depositor at this index
            let ptr := add(_composeMsg, add(32, add(DUAL_OR_LP_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET, mul(_depositorIndex, BYTES_PER_DEPOSITOR))))
            mstore(ptr, or(shl(96, _depositor), _depositAmount)) // Write _depositor and _depositAmount
        }
    }

    /// @dev Resizes the compose message by changing its length.
    /// @param _composeMsg The bytes array with the depositor info.
    /// @param _type The type of the payload to resize.
    /// @param _numDepositors The number of depositors to resize the compose message to accomodate.
    function resizeComposeMsg(bytes memory _composeMsg, DepositType _type, uint256 _numDepositors) internal pure {
        uint256 msgSizeInBytes = (
            _type == DepositType.SINGLE_TOKEN ? SINGLE_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET : DUAL_OR_LP_TOKEN_PAYLOAD_FIRST_DEPOSITOR_OFFSET
        ) + (_numDepositors * BYTES_PER_DEPOSITOR);
        assembly ("memory-safe") {
            mstore(_composeMsg, msgSizeInBytes)
        }
    }

    /*//////////////////////////////////////////////////////////////
                            Decoding Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Reads the DepositType (first byte) and source market hash (following 32 bytes) from the _composeMsg
    /// @param _composeMsg The compose message received in lzCompose
    function readComposeMsgMetadata(bytes memory _composeMsg) internal pure returns (DepositType depositType, bytes32 sourceMarketHash) {
        assembly ("memory-safe") {
            // Pointer to the start of the compose message
            let ptr := add(_composeMsg, 32)
            // Read the first byte as DepositType
            depositType := byte(0, mload(ptr))
            // Read the next 32 bytes as sourceMarketHash
            sourceMarketHash := mload(add(ptr, 1))
        }
    }

    /// @dev Reads the nonce from the _composeMsg
    /// @param _composeMsg The compose message received in lzCompose
    /// @return nonce The nonce associated with the DUAL_OR_LP_TOKEN deposits
    function readNonce(bytes memory _composeMsg) internal pure returns (uint256 nonce) {
        assembly ("memory-safe") {
            // Read the 32 bytes following the metadata as nonce
            nonce := mload(add(_composeMsg, 65))
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
