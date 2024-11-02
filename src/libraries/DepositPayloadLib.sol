// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// An enumeration of deposit types supported by CCDM
enum DepositType {
    SINGLE_TOKEN, // Depositing a single OFT token on destination
    DUAL_TOKEN // Depositing 2 OFT tokens at a predefined ratio on destination

}

/// @title DepositPayloadLib
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice A library for encoding and decoding CCDM payloads
library DepositPayloadLib {
    /*//////////////////////////////////////////////////////////////
                                ENCODE
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes a compose message for SINGLE_TOKEN cross-chain deposits
    /// @param _marketHash The Royco market hash associated with the deposits
    function initSingleTokenComposeMsg(bytes32 _marketHash) internal pure returns (bytes memory composeMsg) {
        composeMsg = abi.encodePacked(DepositType.SINGLE_TOKEN, _marketHash);
    }

    /// @dev Initializes a compose message for DUAL_TOKEN cross-chain deposits
    /// @param _marketHash The Royco market hash associated with the deposits
    /// @param _nonce The nonce associated with the DUAL_TOKEN deposits
    function initDualTokenComposeMsg(bytes32 _marketHash, uint256 _nonce) internal pure returns (bytes memory composeMsg) {
        composeMsg = abi.encodePacked(DepositType.DUAL_TOKEN, _marketHash, _nonce);
    }

    /// @dev Reads the DepositType (first byte) and source market hash (following 32 bytes) from the _composeMsg
    /// @param _composeMsg The compose message to append a depositor to
    function writeDepositor(bytes memory _composeMsg, address _depositor, uint96 _depositAmount) internal pure returns (bytes memory) {
        return abi.encodePacked(_composeMsg, _depositor, _depositAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                DECODE
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
    /// @return nonce The nonce associated with the DUAL_TOKEN deposits
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
