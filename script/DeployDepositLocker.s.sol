// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

import { DepositLocker, RecipeMarketHubBase, IWETH, IUniswapV2Router01, IOFT } from "src/core/DepositLocker.sol";

// Deployer
address constant CREATE2_FACTORY_ADDRESS = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

// Deployment Configuration
address constant DEPOSIT_LOCKER_OWNER = 0xCe6EC1D4401A3CbaEF79942ff257de2dFbC7714f;
uint32 constant DESTINATION_CHAIN_LZ_EID = 40_346; // cArtio
address constant DEPOSIT_EXECUTOR = address(0); // Will be set through setter once deployed
address constant GREEN_LIGHTER = 0x5D1B9186Ac01B7c364734618172CD4487E68bC92;
RecipeMarketHubBase constant RECIPE_MARKET_HUB = RecipeMarketHubBase(0x783251f103555068c1E9D755f69458f39eD937c0);
IWETH constant WRAPPED_NATIVE_ASSET = IWETH(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9);
IUniswapV2Router01 constant UNISWAP_V2_ROUTER = IUniswapV2Router01(0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3);

// Deployment salts
string constant DEPOSIT_LOCKER_SALT = "CCDM_DEPOSIT_LOCKER_ab5c961a833d7d9e9314af142c08055bf24de74a";

// Expected deployment addresses after simulating deployment
address constant EXPECTED_DEPOSIT_LOCKER_ADDRESS = 0x37e0A35512511aaf4233705B7eB5cf7b460854FE;

contract DeployDepositLocker is Script {
    error Create2DeployerNotDeployed();
    error DeploymentFailed(bytes reason);
    error AddressDoesNotContainBytecode(address addr);
    error NotDeployedToExpectedAddress(address expected, address actual);
    error UnexpectedDeploymentAddress(address expected, address actual);
    error DepositLockerOwnerIncorrect(address expected, address actual);

    function _generateUint256SaltFromString(string memory _salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_salt)));
    }

    function _generateDeterminsticAddress(string memory _salt, bytes memory _creationCode) internal pure returns (address) {
        uint256 salt = _generateUint256SaltFromString(_salt);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), CREATE2_FACTORY_ADDRESS, salt, keccak256(_creationCode)));
        return address(uint160(uint256(hash)));
    }

    function _checkDeployer() internal view {
        if (CREATE2_FACTORY_ADDRESS.code.length == 0) {
            revert Create2DeployerNotDeployed();
        }
    }

    function _verifyDepositLockerDeployment(DepositLocker _depositLocker) internal view {
        if (address(_depositLocker) != EXPECTED_DEPOSIT_LOCKER_ADDRESS) {
            revert UnexpectedDeploymentAddress(EXPECTED_DEPOSIT_LOCKER_ADDRESS, address(_depositLocker));
        }

        if (_depositLocker.owner() != DEPOSIT_LOCKER_OWNER) revert DepositLockerOwnerIncorrect(DEPOSIT_LOCKER_OWNER, _depositLocker.owner());
    }

    function _deploy(string memory _salt, bytes memory _creationCode) internal returns (address deployedAddress) {
        (bool success, bytes memory data) = CREATE2_FACTORY_ADDRESS.call(abi.encodePacked(_generateUint256SaltFromString(_salt), _creationCode));

        if (!success) {
            revert DeploymentFailed(data);
        }

        assembly ("memory-safe") {
            deployedAddress := shr(0x60, mload(add(data, 0x20)))
        }
    }

    function _deployWithSanityChecks(string memory _salt, bytes memory _creationCode) internal returns (address) {
        address expectedAddress = _generateDeterminsticAddress(_salt, _creationCode);

        if (address(expectedAddress).code.length != 0) {
            console2.log("contract already deployed at: ", expectedAddress);
            return expectedAddress;
        }

        address addr = _deploy(_salt, _creationCode);

        if (addr != expectedAddress) {
            revert NotDeployedToExpectedAddress(expectedAddress, addr);
        }

        if (address(addr).code.length == 0) {
            revert AddressDoesNotContainBytecode(addr);
        }

        return addr;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        console2.log("Deploying with address: ", deployerAddress);
        console2.log("Deployer Balance: ", address(deployerAddress).balance);

        IOFT[] memory LZ_V2_OFTs = new IOFT[](4);
        LZ_V2_OFTs[0] = IOFT(0x9Cc7e185162Aa5D1425ee924D97a87A0a34A0706);
        LZ_V2_OFTs[1] = IOFT(0x4985b8fcEA3659FD801a5b857dA1D00e985863F0);
        LZ_V2_OFTs[2] = IOFT(0x9D819CcAE96d41d8F775bD1259311041248fF980);
        LZ_V2_OFTs[3] = IOFT(0x552bAC4A13eC7c261903433F1E12e9Eff8dc4adc);

        vm.startBroadcast(deployerPrivateKey);

        _checkDeployer();
        console2.log("Deployer is ready\n");

        // Deploy PointsFactory
        console2.log("Deploying DepositLocker");
        bytes memory depositLockerCreationCode = abi.encodePacked(
            vm.getCode("DepositLocker"),
            abi.encode(
                DEPOSIT_LOCKER_OWNER,
                DESTINATION_CHAIN_LZ_EID,
                DEPOSIT_EXECUTOR,
                GREEN_LIGHTER,
                RECIPE_MARKET_HUB,
                WRAPPED_NATIVE_ASSET,
                UNISWAP_V2_ROUTER,
                LZ_V2_OFTs
            )
        );
        DepositLocker depositLocker = DepositLocker(payable(_deployWithSanityChecks(DEPOSIT_LOCKER_SALT, depositLockerCreationCode)));

        console2.log("Verifying DepositLocker deployment");
        _verifyDepositLockerDeployment(depositLocker);
        console2.log("DepositLocker deployed at: ", address(depositLocker), "\n");

        vm.stopBroadcast();
    }
}
