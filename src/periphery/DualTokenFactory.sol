// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { DepositLocker } from "src/core/DepositLocker.sol";
import { DualToken, ERC20 } from "src/periphery/DualToken.sol";

/// @title DualTokenFactory
/// @notice A simple factory for creating DualTokens
/// @dev Uses CREATE2 for deterministic deployment of DualTokens with predefined ratios of underlying tokens
/// @author Shivaansh Kapoor, Jack Corddry
contract DualTokenFactory {
    // The DepositLocker on the source chain
    DepositLocker immutable DEPOSIT_LOCKER;

    /// @notice Mapping of DualToken address => bool (indicator of if the DualToken was deployed using this factory)
    mapping(address => bool) public isDualToken;

    /// @notice Emitted when creating a DualToken using this factory
    event NewDualToken(DualToken indexed dualToken, string indexed name, string indexed symbol, ERC20 tokenA, ERC20 tokenB);

    /// @notice Emitted when trying to set a token that does not exist
    error TokenDoesNotExist();

    /// @notice Emitted when trying to set a ratio to 0
    error ConstituentAmountsMustBeNonZero();

    /// @notice Error emitted when the amount of token A per DT is too precise to bridge based on the shared decimals of the OFT
    error TokenA_AmountTooPrecise();

    /// @notice Error emitted when the amount of token B per DT is too precise to bridge based on the shared decimals of the OFT
    error TokenB_AmountTooPrecise();

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
    /// @param _tokenA The first ERC20 constituent that will be used in the DualToken
    /// @param _tokenB The second ERC20 constituent that will be used in the DualToken
    /// @param _amountOfTokenAPerDT The amount of tokenA per DualToken
    /// @param _amountOfTokenBPerDT The amount of tokenB per DualToken
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
        // Perform validation checks
        _validateInputs(_tokenA, _tokenB, _amountOfTokenAPerDT, _amountOfTokenBPerDT);

        // Use CREATE2 for deterministic deployment
        bytes32 salt = keccak256(abi.encode(_name, _symbol, _tokenA, _tokenB, _amountOfTokenAPerDT, _amountOfTokenBPerDT));
        dualToken = new DualToken{ salt: salt }(_name, _symbol, _tokenA, _tokenB, _amountOfTokenAPerDT, _amountOfTokenBPerDT);

        // Mark the DualToken as deployed using this factory
        isDualToken[address(dualToken)] = true;

        // Emit the event
        emit NewDualToken(dualToken, _name, _symbol, _tokenA, _tokenB);
    }

    /// @notice Internal helper function to validate the input parameters
    /// @dev Checks that the token addresses are valid and that the amounts per DualToken are non-zero and have valid precision
    /// @param _tokenA The first ERC20 constituent token
    /// @param _tokenB The second ERC20 constituent token
    /// @param _amountOfTokenAPerDT The amount of tokenA per DualToken
    /// @param _amountOfTokenBPerDT The amount of tokenB per DualToken
    function _validateInputs(ERC20 _tokenA, ERC20 _tokenB, uint256 _amountOfTokenAPerDT, uint256 _amountOfTokenBPerDT) internal view {
        // Basic sanity checks
        require(address(_tokenA).code.length > 0 && address(_tokenB).code.length > 0, TokenDoesNotExist());
        require(_amountOfTokenAPerDT > 0 && _amountOfTokenBPerDT > 0, ConstituentAmountsMustBeNonZero());

        // Check that the deposit amount for each constituent is less or equally as precise as specified by the shared decimals of the corresponding OFT
        // This is to ensure precise amounts sent from source to destination on a DualToken bridge
        bool amountOfTokenAPerDTHasValidPrecision =
            _amountOfTokenAPerDT % (10 ** (_tokenA.decimals() - DEPOSIT_LOCKER.tokenToLzV2OFT(_tokenA).sharedDecimals())) == 0;
        require(amountOfTokenAPerDTHasValidPrecision, TokenA_AmountTooPrecise());

        bool amountOfTokenBPerDTHasValidPrecision =
            _amountOfTokenBPerDT % (10 ** (_tokenB.decimals() - DEPOSIT_LOCKER.tokenToLzV2OFT(_tokenB).sharedDecimals())) == 0;
        require(amountOfTokenBPerDTHasValidPrecision, TokenB_AmountTooPrecise());
    }
}
