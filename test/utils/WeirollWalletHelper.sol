// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { WeirollWallet } from "@royco/src/WeirollWallet.sol";

/// @title WeirollWalletHelper
/// @notice A helper contract to enable calling view functions of WeirollWallet via DELEGATECALL.
/// @dev This contract contains view functions that can be called via DELEGATECALL to access the state of a WeirollWallet contract.
contract WeirollWalletHelper {
    /// @notice Gets the address of the WeirollWallet.
    /// @dev Returns address(this) as a payable address.
    /// @return The address of the WeirollWallet.
    function thisWallet() external view returns (address payable) {
        return payable(address(this));
    }

    /// @notice Gets the native balance of the WeirollWallet.
    /// @dev Returns this.balance.
    /// @return The ether balance of the WeirollWallet.
    function nativeBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Gets the owner of the WeirollWallet.
    /// @dev Calls the `owner()` function of the WeirollWallet contract using `address(this)`.
    /// @return The address of the owner.
    function owner() external view returns (address) {
        return WeirollWallet(payable(address(this))).owner();
    }

    /// @notice Gets the address of the RecipeMarketHub contract associated with the WeirollWallet.
    /// @dev Calls the `recipeMarketHub()` function of the WeirollWallet contract using `address(this)`.
    /// @return The address of the RecipeMarketHub contract.
    function recipeMarketHub() external view returns (address) {
        return WeirollWallet(payable(address(this))).recipeMarketHub();
    }

    /// @notice Gets the amount of tokens deposited into the WeirollWallet.
    /// @dev Calls the `amount()` function of the WeirollWallet contract using `address(this)`.
    /// @return The amount of tokens deposited.
    function amount() external view returns (uint256) {
        return WeirollWallet(payable(address(this))).amount();
    }

    /// @notice Gets the timestamp until which the WeirollWallet is locked.
    /// @dev Calls the `lockedUntil()` function of the WeirollWallet contract using `address(this)`.
    /// @return The timestamp (in seconds since epoch) after which the wallet may be interacted with.
    function lockedUntil() external view returns (uint256) {
        return WeirollWallet(payable(address(this))).lockedUntil();
    }

    /// @notice Determines if the WeirollWallet is forfeitable.
    /// @dev Calls the `isForfeitable()` function of the WeirollWallet contract using `address(this)`.
    /// @return A boolean indicating if the wallet is forfeitable.
    function isForfeitable() external view returns (bool) {
        return WeirollWallet(payable(address(this))).isForfeitable();
    }

    /// @notice Gets the hash of the market associated with the WeirollWallet.
    /// @dev Calls the `marketHash()` function of the WeirollWallet contract using `address(this)`.
    /// @return The market hash as a bytes32.
    function marketHash() external view returns (bytes32) {
        return WeirollWallet(payable(address(this))).marketHash();
    }

    /// @notice Checks if the order associated with the WeirollWallet has been executed.
    /// @dev Calls the `executed()` function of the WeirollWallet contract using `address(this)`.
    /// @return A boolean indicating if the order has been executed.
    function executed() external view returns (bool) {
        return WeirollWallet(payable(address(this))).executed();
    }

    /// @notice Checks if the WeirollWallet has been forfeited.
    /// @dev Calls the `forfeited()` function of the WeirollWallet contract using `address(this)`.
    /// @return A boolean indicating if the wallet has been forfeited.
    function forfeited() external view returns (bool) {
        return WeirollWallet(payable(address(this))).forfeited();
    }
}
