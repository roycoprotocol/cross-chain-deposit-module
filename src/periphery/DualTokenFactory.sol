// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { DualToken, ERC20, DepositLocker } from "src/core/DepositLocker.sol";

/// @title DualTokenFactory
/// @author Shivaansh Kapoor, Jack Corddry
/// @dev A simple factory for creating DualTokens
contract DualTokenFactory {
    // The DepositLocker on the source chain
    DepositLocker immutable DEPOSIT_LOCKER;

    /// @notice Mapping of DualToken address => bool (indicator of if the DualToken was deployed using this factory)
    mapping(address => bool) public isDualToken;

    /// @notice Emitted when creating a DualToken using this factory
    event NewDualToken(DualToken indexed dualToken, string indexed name, string indexed symbol, ERC20 tokenA, ERC20 tokenB);

    /// @param _depositLocker The DepositLocker on the source chain
    constructor(DepositLocker _depositLocker) {
        DEPOSIT_LOCKER = _depositLocker;
    }

    /// @notice Creates a new DualToken contract
    /// @dev Uses CREATE2 for deterministic deployment. The DualToken is initialized with the provided parameters,
    ///      and the address of the new DualToken is marked in the `isDualToken` mapping.
    /// @dev All DualTokens have 18 decimals
    /// @param _name The name of the new DualToken
    /// @param _symbol The symbol of the new DualToken
    /// @param _tokenA The first ERC20 token that will be used in the DualToken
    /// @param _tokenB The second ERC20 token that will be used in the DualToken
    /// @param _amountOfTokenAPerDT The amount of tokenA per DualToken unit
    /// @param _amountOfTokenBPerDT The amount of tokenB per DualToken unit
    /// @return dualToken The newly created DualToken
    function createDualToken(
        string memory _name,
        string memory _symbol,
        ERC20 _tokenA,
        ERC20 _tokenB,
        uint256 _amountOfTokenAPerDT,
        uint256 _amountOfTokenBPerDT
    )
        external
        returns (DualToken dualToken)
    {
        bytes32 salt = keccak256(abi.encode(_name, _symbol, _tokenA, _tokenB, _amountOfTokenAPerDT, _amountOfTokenBPerDT));
        dualToken = new DualToken{ salt: salt }(_name, _symbol, DEPOSIT_LOCKER, _tokenA, _tokenB, _amountOfTokenAPerDT, _amountOfTokenBPerDT);
        isDualToken[address(dualToken)] = true;

        emit NewDualToken(dualToken, _name, _symbol, _tokenA, _tokenB);
    }
}
