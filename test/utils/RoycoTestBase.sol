// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@royco/test/mocks/MockRecipeMarketHub.sol";

import { MockERC20 } from "@royco/test/mocks/MockERC20.sol";
import { IUniswapV2Router01 } from "@uniswap-v2/periphery/contracts/interfaces/IUniswapV2Router01.sol";

import "lib/forge-std/src/Test.sol";
import "lib/forge-std/src/Vm.sol";

contract RoycoTestBase is Test {
    // -----------------------------------------
    // Constants
    // -----------------------------------------

    // Address of wBTC on ETH
    address WBTC_MAINNET_ADDRESS = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    // Address of wBTC OFT Adapter on ETH
    address WBTC_OFT_ADAPTER_MAINNET_ADDRESS = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    address WETH_MAINNET_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address USDC_MAINNET_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address USDT_MAINNET_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address STARGATE_USDC_POOL_MAINNET_ADDRESS = 0xc026395860Db2d07ee33e05fE50ed7bD583189C7;
    address STARGATE_USDT_POOL_MAINNET_ADDRESS = 0x933597a323Eb81cAe705C5bC29985172fd5A3973;
    address STARGATE_POOL_NATIVE_MAINNET_ADDRESS = 0x77b2043768d28E9C9aB44E1aBfC95944bcE57931;

    address USDC_POLYGON_ADDRESS = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address USDT_POLYGON_ADDRESS = 0xc2132D05D31c914a87C6611C10748AEb04B58e8F;

    address STARGATE_USDC_POOL_POLYGON_ADDRESS = 0x9Aa02D4Fae7F58b8E8f34c66E756cC734DAc7fe4;

    IUniswapV2Router01 UNISWAP_V2_MAINNET_ROUTER_ADDRESS = IUniswapV2Router01(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // -----------------------------------------
    // Test Wallets
    // -----------------------------------------
    Vm.Wallet internal OWNER;
    address internal OWNER_ADDRESS;

    Vm.Wallet internal MULTISIG;
    address internal MULTISIG_ADDRESS;

    Vm.Wallet internal POINTS_FACTORY_OWNER;
    address internal POINTS_FACTORY_OWNER_ADDRESS;

    Vm.Wallet internal ALICE;
    Vm.Wallet internal BOB;
    Vm.Wallet internal CHARLIE;
    Vm.Wallet internal DAN;

    address internal ALICE_ADDRESS;
    address internal BOB_ADDRESS;
    address internal CHARLIE_ADDRESS;
    address internal DAN_ADDRESS;

    // -----------------------------------------
    // Royco Contracts
    // -----------------------------------------
    WeirollWallet public weirollImplementation;
    MockRecipeMarketHub public recipeMarketHub;
    MockERC20 public mockLiquidityToken;
    MockERC20 public mockIncentiveToken;
    PointsFactory public pointsFactory;

    // -----------------------------------------
    // Modifiers
    // -----------------------------------------
    modifier prankModifier(address pranker) {
        vm.startPrank(pranker);
        _;
        vm.stopPrank();
    }

    // -----------------------------------------
    // Setup Functions
    // -----------------------------------------
    function setupBaseEnvironment() internal virtual {
        setupWallets();
        setUpRoycoContracts();
    }

    function initWallet(string memory name, uint256 amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(name);
        vm.label(wallet.addr, name);
        vm.deal(wallet.addr, amount);
        return wallet;
    }

    function setupWallets() internal {
        // Init wallets with 1000 ETH each
        OWNER = initWallet("OWNER", 1000 ether);
        MULTISIG = initWallet("MULTISIG", 1000 ether);
        POINTS_FACTORY_OWNER = initWallet("POINTS_FACTORY_OWNER", 1000 ether);
        ALICE = initWallet("ALICE", 1000 ether);
        BOB = initWallet("BOB", 1000 ether);
        CHARLIE = initWallet("CHARLIE", 1000 ether);
        DAN = initWallet("DAN", 1000 ether);

        // Set addresses
        OWNER_ADDRESS = OWNER.addr;
        MULTISIG_ADDRESS = MULTISIG.addr;
        POINTS_FACTORY_OWNER_ADDRESS = POINTS_FACTORY_OWNER.addr;
        ALICE_ADDRESS = ALICE.addr;
        BOB_ADDRESS = BOB.addr;
        CHARLIE_ADDRESS = CHARLIE.addr;
        DAN_ADDRESS = DAN.addr;
    }

    function setUpRoycoContracts() internal {
        weirollImplementation = new WeirollWallet();
        mockLiquidityToken = new MockERC20("Mock Liquidity Token", "MLT");
        mockIncentiveToken = new MockERC20("Mock Incentive Token", "MIT");
        pointsFactory = new PointsFactory(POINTS_FACTORY_OWNER_ADDRESS);
    }

    /**
     * @dev Internal function to remove dust from the given local decimal amount.
     * @param _amountLD The amount in local decimals.
     * @return amountLD The amount after removing dust.
     *
     * @dev Prevents the loss of dust when moving amounts between chains with different decimals.
     * @dev eg. uint(123) with a conversion rate of 100 becomes uint(100).
     */
    function _removeDust(uint256 _amountLD, uint8 _localDecimals, uint8 _sharedDecimals) internal view virtual returns (uint256 amountLD) {
        uint256 decimalConversionRate = 10 ** (_localDecimals - _sharedDecimals);
        return (_amountLD / decimalConversionRate) * decimalConversionRate;
    }
}
