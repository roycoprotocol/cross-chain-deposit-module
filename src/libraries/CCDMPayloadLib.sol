// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title CCDMPayloadLib
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A library for encoding and decoding CCDM payloads
library CCDMPayloadLib {
    /*//////////////////////////////////////////////////////////////
                      CCDM Payload Structure
                ----------------------------------
    Per Payload Metadata (first 67 bytes):
        - Market Hash: bytes32 (32 bytes)
        - CCDM Nonce: uint256 (32 bytes)
        - Number of Tokens Bridged: uint8 (1 byte)
        - Bridged Token's Decimals on the Source Chain: uint8 (1 byte)
        - Bridge Type: uint8 (1 byte)

    MERKLE_DEPOSITORS Data:
        - Merkle Root: bytes32 (32 bytes)
        - Total Amount Deposited on Source: uint256 (32 bytes)

    INDIVIDUAL_DEPOSITORS Data:
        Per Depositor (following 32 byte blocks):
            - Depositor / AP address: address (20 bytes)
            - Amount Deposited: uint96 (12 bytes)
    //////////////////////////////////////////////////////////////*/

    /// @notice Enum for indicating the type of CCDM bridge (merkle or individual).
    enum BridgeType {
        MERKLE_DEPOSITORS,
        INDIVIDUAL_DEPOSITORS
    }

    /// @notice Size of a MERKLE_DEPOSITORS payload.
    uint256 internal constant MERKLE_DEPOSITORS_PAYLOAD_SIZE = 131;

    /// @notice Size of the per payload metadata (and merkle root / offset to the first depositor) in a CCDM payload.
    uint256 internal constant METADATA_SIZE = 67;

    /// @notice Size of the per depositor data in a CCDM payload.
    uint256 internal constant BYTES_PER_DEPOSITOR = 32;

    /*//////////////////////////////////////////////////////////////
                            Encoding Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes a compose message for CCDM.
    /// @param _numDepositors The number of depositors that will be bridged using this compose message.
    /// This is only set for INDIVIDUAL_DEPOSITORS bridges.
    /// @param _marketHash The Royco market hash associated with the deposits.
    /// @param _ccdmNonce The ccdmNonce associated with the DUAL_OR_LP_TOKEN deposits.
    /// @param _numTokensBridged The number of input tokens bridged for the destination campaign.
    /// @param _srcChainTokenDecimals The source chain's decimals for the token bridged.
    /// @param _bridgeType The type of CCDM bridge (merkle or individual).
    /// @return composeMsg The compose message initialized with the params.
    function initComposeMsg(
        uint256 _numDepositors,
        bytes32 _marketHash,
        uint256 _ccdmNonce,
        uint8 _numTokensBridged,
        uint8 _srcChainTokenDecimals,
        BridgeType _bridgeType
    )
        internal
        pure
        returns (bytes memory composeMsg)
    {
        uint256 msgSizeInBytes =
            _bridgeType == BridgeType.MERKLE_DEPOSITORS ? MERKLE_DEPOSITORS_PAYLOAD_SIZE : METADATA_SIZE + (_numDepositors * BYTES_PER_DEPOSITOR);
        composeMsg = new bytes(msgSizeInBytes);
        assembly ("memory-safe") {
            let ptr := add(composeMsg, 32) // Pointer to the start of the data in _composeMsg
            mstore(ptr, _marketHash) // Write _marketHash (32 bytes)
            mstore(add(ptr, 32), _ccdmNonce) // Write _ccdmNonce (32 bytes)
            mstore8(add(ptr, 64), _numTokensBridged) // Write _numTokensBridged (1 byte)
            mstore8(add(ptr, 65), _srcChainTokenDecimals) // Write _srcChainTokenDecimals (1 byte)
            mstore8(add(ptr, 66), _bridgeType) // Write _bridgeType (1 byte)
        }
    }

    /// @dev Writes a merkle root to the _composeMsg right after the metadata.
    /// @param _composeMsg The bytes array to which the merkle root will be written to.
    /// @param _merkleRoot The merkle root for this CCDM bridge payload.
    /// @param _totalAmountDepositedOnSource The total amount of deposits held by the merkle root.
    function writeMerkleBridgeData(bytes memory _composeMsg, bytes32 _merkleRoot, uint256 _totalAmountDepositedOnSource) internal pure {
        assembly ("memory-safe") {
            // The memory pointer for the depositor at this index
            let ptr := add(_composeMsg, add(32, METADATA_SIZE))
            mstore(ptr, _merkleRoot) // Write the _merkleRoot as the first word
            mstore(add(ptr, 32), _totalAmountDepositedOnSource) // Write the _totalAmountDepositedOnSource as the second word
        }
    }

    /// @dev Writes a depositor and their amount directly into the _composeMsg at a particular index.
    /// @dev The index must be within the bounds of the payload size.
    /// @param _composeMsg The bytes array to which the depositor information will be written to.
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

    /// @dev Reads the per payload metadata of the _composeMsg.
    /// @param _composeMsg The compose message received in lzCompose.
    /// @return sourceMarketHash The Royco market hash associated with the deposits.
    /// @return ccdmNonce The ccdmNonce associated with the DUAL_OR_LP_TOKEN deposits.
    /// @return numTokensBridged The number of input tokens bridged for the destination campaign.
    /// @return srcChainTokenDecimals The source chain's decimals for the token bridged.
    /// @return bridgeType The type of CCDM bridge (merkle or individual).
    function readComposeMsgMetadata(bytes memory _composeMsg)
        internal
        pure
        returns (bytes32 sourceMarketHash, uint256 ccdmNonce, uint8 numTokensBridged, uint8 srcChainTokenDecimals, BridgeType bridgeType)
    {
        assembly ("memory-safe") {
            // Pointer to the start of the compose message data (first 32 bytes is the length)
            let ptr := add(_composeMsg, 32)
            // Read the first 32 bytes as sourceMarketHash
            sourceMarketHash := mload(ptr)
            // Read the next 32 bytes as ccdmNonce
            ccdmNonce := mload(add(ptr, 32))
            // Read the next 32 bytes into a buffer
            let buffer := mload(add(ptr, 64))
            // Read the highest byte of the buffer as numTokensBridged
            numTokensBridged := shr(248, buffer)
            // Read the second highest byte of the buffer as srcChainTokenDecimals
            // Bit mask negates everything but the lowest byte after the right shift
            srcChainTokenDecimals := and(shr(240, buffer), 0xFF)
            // Read the third highest byte of the buffer as bridgeType
            // Bit mask negates everything but the lowest byte after the right shift
            bridgeType := and(shr(232, buffer), 0xFF)
        }
    }

    /// @dev Reads the merkle root of the _composeMsg.
    /// @param _composeMsg The compose message received in lzCompose
    /// @return merkleRoot The address read from the composeMsg at the specified offset.
    /// @return totalAmountDepositedOnSource The total amount of deposits held by the merkle root.
    function readMerkleBridgeData(bytes memory _composeMsg) internal pure returns (bytes32 merkleRoot, uint256 totalAmountDepositedOnSource) {
        assembly ("memory-safe") {
            let ptr := add(_composeMsg, add(32, METADATA_SIZE))
            merkleRoot := mload(ptr) // Read the merkleRoot as the first word
            totalAmountDepositedOnSource := mload(add(ptr, 32)) // Read the totalAmountDepositedOnSource as the second word
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
