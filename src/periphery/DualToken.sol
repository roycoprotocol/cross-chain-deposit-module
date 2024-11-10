// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Import statements
import { ERC20, SafeTransferLib } from "@royco/src/RecipeMarketHub.sol";
import { DepositLocker } from "src/core/DepositLocker.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title DualToken
/// @author Shivaansh Kapoor, Jack Corddry
/// @notice An ERC20 token representing ownership of two underlying tokens at a predefined ratio
/// @notice DualTokens are burned (redeemed) for their constituents by the DepositLocker and each token is bridged individually
contract DualToken is ERC20, ReentrancyGuardTransient {
    using SafeTransferLib for ERC20;

    /// @notice DualTokens can only be represented as whole numbers
    uint8 public constant DUAL_OR_LP_TOKEN_DECIMALS = 0;

    /// @notice The first underlying ERC20 token
    ERC20 public immutable tokenA;

    /// @notice The second underlying ERC20 token
    ERC20 public immutable tokenB;

    /// @notice The amount of tokenA backing 1 DualToken
    uint256 public immutable amountOfTokenAPerDT;

    /// @notice The amount of tokenB backing 1 DualToken
    uint256 public immutable amountOfTokenBPerDT;

    /// @notice Emitted when trying to mint 0 tokens
    error MintAmountMustBeNonZero();

    /// @notice Emitted when trying to burn 0 tokens
    error BurnAmountMustBeNonZero();

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
        ERC20(_name, _symbol, DUAL_OR_LP_TOKEN_DECIMALS)
    {
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
        uint256 tokenAAmount = amount * amountOfTokenAPerDT;
        uint256 tokenBAmount = amount * amountOfTokenBPerDT;

        // Transfer amounts of tokenA and tokenB from the user to this contract
        tokenA.safeTransferFrom(msg.sender, address(this), tokenAAmount);
        tokenB.safeTransferFrom(msg.sender, address(this), tokenBAmount);

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
        uint256 tokenAAmount = amount * amountOfTokenAPerDT;
        uint256 tokenBAmount = amount * amountOfTokenBPerDT;

        // Burn the DualTokens from the user
        _burn(msg.sender, amount);

        // Transfer tokenA and tokenB back to the user
        tokenA.safeTransfer(msg.sender, tokenAAmount);
        tokenB.safeTransfer(msg.sender, tokenBAmount);
    }
}
