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
    ERC20 public immutable tokenA;

    /// @notice The second underlying ERC20 token
    ERC20 public immutable tokenB;

    /// @notice The amount of tokenA backing 1 DualToken
    uint256 public immutable amountOfTokenAPerDT;

    /// @notice The amount of tokenB backing 1 DualToken
    uint256 public immutable amountOfTokenBPerDT;

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
     * @param _tokenA Address of the first underlying token
     * @param _tokenB Address of the second underlying token
     * @param _amountOfTokenAPerDT The amount of tokenA backing 1 DualToken
     * @param _amountOfTokenBPerDT The amount of tokenB backing 1 DualToken
     */
    constructor(
        string memory _name,
        string memory _symbol,
        ERC20 _tokenA,
        ERC20 _tokenB,
        uint256 _amountOfTokenAPerDT,
        uint256 _amountOfTokenBPerDT
    )
        ERC20(_name, _symbol, DUAL_TOKEN_DECIMALS)
    {
        require(address(_tokenA).code.length > 0 && address(_tokenB).code.length > 0, TokenDoesNotExist());
        require(_amountOfTokenAPerDT > 0 && _amountOfTokenBPerDT > 0, CollateralMustBeNonZero());

        tokenA = _tokenA;
        tokenB = _tokenB;
        amountOfTokenAPerDT = _amountOfTokenAPerDT;
        amountOfTokenBPerDT = _amountOfTokenBPerDT;
    }

    /**
     * @notice Mint DualTokens by providing the required amounts of tokenA and tokenB
     * @param amount The amount of DualTokens to mint
     */
    function mint(uint256 amount) external nonReentrant {
        require(amount > 0, MintAmountMustBeNonZero());

        // Calculate the amounts of tokenA and tokenB to transfer from the user
        uint256 tokenAAmount = amount.mulWadUp(amountOfTokenAPerDT);
        uint256 tokenBAmount = amount.mulWadUp(amountOfTokenBPerDT);

        // Transfer tokenA from the user to this contract
        uint256 initialTokenBalance = tokenA.balanceOf(address(this));
        tokenA.safeTransferFrom(msg.sender, address(this), tokenAAmount);
        uint256 resultingTokenBalance = tokenA.balanceOf(address(this));
        require(resultingTokenBalance - initialTokenBalance == tokenAAmount, SafeTransferFromFailed());

        // Transfer tokenB from the user to this contract
        initialTokenBalance = tokenB.balanceOf(address(this));
        tokenB.safeTransferFrom(msg.sender, address(this), tokenBAmount);
        resultingTokenBalance = tokenB.balanceOf(address(this));
        require(resultingTokenBalance - initialTokenBalance == tokenBAmount, SafeTransferFromFailed());

        // Mint DualTokens to the user
        _mint(msg.sender, amount);
    }

    /**
     * @notice Burn DualTokens to redeem the underlying tokenA and tokenB
     * @param amount The amount of DualTokens to burn
     */
    function burn(uint256 amount) external nonReentrant {
        require(amount > 0, BurnAmountMustBeNonZero());

        // Calculate the amounts of tokenA and tokenB to return to the user
        uint256 tokenAAmount = amount.mulWadDown(amountOfTokenAPerDT);
        uint256 tokenBAmount = amount.mulWadDown(amountOfTokenBPerDT);

        // Burn the DualTokens from the user
        _burn(msg.sender, amount);

        // Transfer tokenA and tokenB back to the user
        tokenA.safeTransfer(msg.sender, tokenAAmount);
        tokenB.safeTransfer(msg.sender, tokenBAmount);
    }
}
