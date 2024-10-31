// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import statements
import { ERC20, SafeTransferLib, FixedPointMathLib } from "@royco/src/RecipeMarketHub.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title DualToken
/// @notice An ERC20 token representing ownership of two underlying tokens at a predefined ratio
contract DualToken is ERC20, ReentrancyGuardTransient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice Decimals for the DualToken (set to 18)
    uint8 public constant DUAL_TOKEN_DECIMALS = 18;

    /// @notice The first underlying ERC20 token
    ERC20 public immutable token1;

    /// @notice The second underlying ERC20 token
    ERC20 public immutable token2;

    /// @notice The amount of token1 backing 1 DualToken
    uint256 public immutable amountToken1PerDT;

    /// @notice The amount of token2 backing 1 DualToken
    uint256 public immutable amountToken2PerDT;

    /// @notice Emitted when trying to set a token that does not exist
    error TokenDoesNotExist();

    /// @notice Emitted when trying to set a ratio to 0
    error CollateralMustBeNonZero();

    /// @notice Emitted when trying to mint 0 tokens
    error MintAmountMustBeNonZero();

    /// @notice Emitted when trying to burn 0 tokens
    error BurnAmountMustBeNonZero();

    /// @notice Emitted when safeTransferFrom doesn't transfer the correct amount of tokens
    error SafeTransferFromFailed();

    /**
     * @notice Constructor to initialize the DualToken contract
     * @param _name Name of the DualToken
     * @param _symbol Symbol of the DualToken
     * @param _token1 Address of the first underlying token
     * @param _token2 Address of the second underlying token
     * @param _amountToken1PerDT The amount of token1 backing 1 DualToken
     * @param _amountToken2PerDT The amount of token2 backing 1 DualToken
     */
    constructor(
        string memory _name,
        string memory _symbol,
        ERC20 _token1,
        ERC20 _token2,
        uint256 _amountToken1PerDT,
        uint256 _amountToken2PerDT
    )
        ERC20(_name, _symbol, DUAL_TOKEN_DECIMALS)
    {
        require(address(_token1).code.length > 0 && address(_token2).code.length > 0, TokenDoesNotExist());
        require(_amountToken1PerDT > 0 && _amountToken2PerDT > 0, CollateralMustBeNonZero());

        token1 = _token1;
        token2 = _token2;
        amountToken1PerDT = _amountToken1PerDT;
        amountToken2PerDT = _amountToken2PerDT;
    }

    /**
     * @notice Mint DualTokens by providing the required amounts of token1 and token2
     * @param amount The amount of DualTokens to mint
     */
    function mint(uint256 amount) external nonReentrant {
        require(amount > 0, MintAmountMustBeNonZero());

        // Calculate the amounts of token1 and token2 to transfer from the user
        uint256 token1Amount = amount.mulWadUp(amountToken1PerDT);
        uint256 token2Amount = amount.mulWadUp(amountToken2PerDT);

        // Transfer token1 from the user to this contract
        uint256 initialTokenBalance = token1.balanceOf(address(this));
        token1.safeTransferFrom(msg.sender, address(this), token1Amount);
        uint256 resultingTokenBalance = token1.balanceOf(address(this));
        require(resultingTokenBalance - initialTokenBalance == token1Amount, SafeTransferFromFailed());

        // Transfer token2 from the user to this contract
        initialTokenBalance = token2.balanceOf(address(this));
        token2.safeTransferFrom(msg.sender, address(this), token2Amount);
        resultingTokenBalance = token2.balanceOf(address(this));
        require(resultingTokenBalance - initialTokenBalance == token2Amount, SafeTransferFromFailed());

        // Mint DualTokens to the user
        _mint(msg.sender, amount);
    }

    /**
     * @notice Burn DualTokens to redeem the underlying token1 and token2
     * @param amount The amount of DualTokens to burn
     */
    function burn(uint256 amount) external nonReentrant {
        require(amount > 0, BurnAmountMustBeNonZero());

        // Calculate the amounts of token1 and token2 to return to the user
        uint256 token1Amount = amount.mulWadDown(amountToken1PerDT);
        uint256 token2Amount = amount.mulWadDown(amountToken2PerDT);

        // Burn the DualTokens from the user
        _burn(msg.sender, amount);

        // Transfer token1 and token2 back to the user
        token1.safeTransfer(msg.sender, token1Amount);
        token2.safeTransfer(msg.sender, token2Amount);
    }
}
