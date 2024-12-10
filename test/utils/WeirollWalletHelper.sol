// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { WeirollWallet } from "../../lib/royco/src/WeirollWallet.sol";

/// @title WeirollWalletHelper
/// @notice A helper contract to enable calling view functions of WeirollWallet via STATICCALL.
/// @author Shivaansh Kapoor, Jack Corddry
/// @dev This contract contains view functions that can be called via STATICCALL to access the state of a WeirollWallet contract.
contract WeirollWalletHelper {
    /// @notice Gets the address of the WeirollWallet.
    /// @dev Returns msg.sender (Weiroll Wallet) as a payable address.
    /// @return The address of the WeirollWallet.
    function thisWallet() external view returns (address payable) {
        return payable(msg.sender);
    }

    /// @notice Gets the native balance of the WeirollWallet.
    /// @dev Returns (msg.sender).balance.
    /// @return The ether balance of the WeirollWallet.
    function nativeBalance() external view returns (uint256) {
        return (msg.sender).balance;
    }

    /// @notice Gets the owner of the WeirollWallet.
    /// @dev Calls the `owner()` function of the WeirollWallet contract using `msg.sender`.
    /// @return The address of the owner.
    function owner() external view returns (address) {
        return WeirollWallet(payable(msg.sender)).owner();
    }

    /// @notice Gets the address of the RecipeMarketHub contract associated with the WeirollWallet.
    /// @dev Calls the `recipeMarketHub()` function of the WeirollWallet contract using `msg.sender`.
    /// @return The address of the RecipeMarketHub contract.
    function recipeMarketHub() external view returns (address) {
        return WeirollWallet(payable(msg.sender)).recipeMarketHub();
    }

    /// @notice Gets the amount of tokens deposited into the WeirollWallet.
    /// @dev Calls the `amount()` function of the WeirollWallet contract using `msg.sender`.
    /// @return The amount of tokens deposited.
    function amount() external view returns (uint256) {
        return WeirollWallet(payable(msg.sender)).amount();
    }

    /// @notice Gets the timestamp until which the WeirollWallet is locked.
    /// @dev Calls the `lockedUntil()` function of the WeirollWallet contract using `msg.sender`.
    /// @return The timestamp (in seconds since epoch) after which the wallet may be interacted with.
    function lockedUntil() external view returns (uint256) {
        return WeirollWallet(payable(msg.sender)).lockedUntil();
    }

    /// @notice Determines if the WeirollWallet is forfeitable.
    /// @dev Calls the `isForfeitable()` function of the WeirollWallet contract using `msg.sender`.
    /// @return A boolean indicating if the wallet is forfeitable.
    function isForfeitable() external view returns (bool) {
        return WeirollWallet(payable(msg.sender)).isForfeitable();
    }

    /// @notice Gets the hash of the market associated with the WeirollWallet.
    /// @dev Calls the `marketHash()` function of the WeirollWallet contract using `msg.sender`.
    /// @return The market hash as a bytes32.
    function marketHash() external view returns (bytes32) {
        return WeirollWallet(payable(msg.sender)).marketHash();
    }

    /// @notice Checks if the order associated with the WeirollWallet has been executed.
    /// @dev Calls the `executed()` function of the WeirollWallet contract using `msg.sender`.
    /// @return A boolean indicating if the order has been executed.
    function executed() external view returns (bool) {
        return WeirollWallet(payable(msg.sender)).executed();
    }

    /// @notice Checks if the WeirollWallet has been forfeited.
    /// @dev Calls the `forfeited()` function of the WeirollWallet contract using `msg.sender`.
    /// @return A boolean indicating if the wallet has been forfeited.
    function forfeited() external view returns (bool) {
        return WeirollWallet(payable(msg.sender)).forfeited();
    }
}
